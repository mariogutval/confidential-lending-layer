import { expect } from "chai";
import { ethers, network } from "hardhat";
import { Log } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { createInstance } from "../instance";
import { reencryptEuint64 } from "../reencrypt";
import { getSigners, initSigners } from "../signers";
import { debug } from "../utils";
import { GATEWAYCONTRACT_ADDRESS } from "../constants";
import { setCodeMocked } from "../mockedSetup";
import { awaitAllDecryptionResults, initGateway } from "../asyncDecrypt";

import hre from "hardhat";

interface Signers {
  alice: any;
  bob: any;
  carol: any;
}

interface LogWithFragment extends Log {
  fragment?: {
    name: string;
  };
  args: any[];
}

async function deployCoreFixture() {
    const signers = await getSigners() as Signers;
  
    // ── Deploy mock ERC‑20 tokens ─────────────────────────────────────────
    const ERC20 = await ethers.getContractFactory("MockERC20");
    const coll  = await ERC20.deploy("Wrapped Ether", "WETH");
    const debt  = await ERC20.deploy("USD Coin", "USDC");
  
    // Give Alice collateral and seed USDC for liquidity tests
    await coll.mint(signers.alice, ethers.parseEther("10"));
  
    // ── Deploy MockPool and pre‑fund with 10 000 USDC ────────────────────
    const Pool = await ethers.getContractFactory("MockPool");
    const pool = await Pool.deploy(coll.getAddress(), debt.getAddress());
    await debt.mint(await pool.getAddress(), ethers.parseUnits("10000", 6));
  
    // ── Deploy Confidential Lending Core ─────────────────────────────────
    const Core = await ethers.getContractFactory("ConfidentialLendingCore");
    const core = await Core.deploy(coll.getAddress(), debt.getAddress(), pool.getAddress());
    await core.waitForDeployment();
  
    return { core, coll, debt, pool };
}

describe("ConfidentialLendingCore", function () {
  before(async function () {    
    // Initialize signers
    await initSigners();
    this.signers = await getSigners();
    this.fhevm = await createInstance();
    await initGateway();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    this.coll = await MockERC20.deploy("Collateral", "COLL");
    this.debt = await MockERC20.deploy("Debt", "DEBT");

    // Deploy mock pool
    const MockPool = await ethers.getContractFactory("MockPool");
    this.pool = await MockPool.deploy(this.coll.getAddress(), this.debt.getAddress());

    // Deploy core contract
    const ConfidentialLendingCore = await ethers.getContractFactory("ConfidentialLendingCore");
    this.core = await ConfidentialLendingCore.deploy(
      await this.coll.getAddress(),
      await this.debt.getAddress(),
      await this.pool.getAddress()
    );

    // Fund the pool with debt tokens
    await this.debt.mint(await this.pool.getAddress(), ethers.parseEther("1000000"));
  });

  beforeEach(async function () {
    const { core, coll, debt, pool } = await deployCoreFixture();
    this.core  = core;
    this.coll  = coll;
    this.debt  = debt;
    this.pool  = pool;
  });

  it("should accept a collateral deposit and expose encrypted balance", async function () {
    await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("3"));
    const zeroIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    zeroIn.add64(0);
    const encZero = await zeroIn.encrypt();
    await (await this.core.depositCollateral(
      ethers.parseEther("3"), encZero.handles[0], encZero.inputProof)).wait();

    const handle = await this.core.encryptedCollOf(this.signers.alice);
    const val = await reencryptEuint64(this.signers.alice, this.fhevm, handle, await this.core.getAddress());
    expect(val).to.equal(ethers.parseEther("3"));
  });

  it("should queue a borrow and settle via callback in mocked mode", async function () {
    // Deposit collateral first
    await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
    const zeroIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    zeroIn.add64(0);
    const encZero = await zeroIn.encrypt();
    await (await this.core.depositCollateral(
      ethers.parseEther("5"), encZero.handles[0], encZero.inputProof)).wait();

    // Request borrow - using a smaller amount that satisfies the vault health check
    const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    encIn.add64(100 * 1e6); // Reduced from 1000 to 100 USDC
    const encAmt = await encIn.encrypt();
    const tx = await this.core.borrow(encAmt.handles[0], encAmt.inputProof);
    await tx.wait();

    // Wait for the gateway to process the decryption and call the callback
    await awaitAllDecryptionResults();

    // Check the balance
    const bal = await this.debt.balanceOf(this.signers.alice);
    expect(bal).to.equal(100 * 1e6);
  });

  it("should ignore an over‑repayment", async function () {
    // Alice deposits and borrows 5 000 USDC
    await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
    const zeroIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    zeroIn.add64(0);
    const encZ = await zeroIn.encrypt();
    await (await this.core.depositCollateral(
      ethers.parseEther("5"), encZ.handles[0], encZ.inputProof)).wait();

    const encBorrow = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    encBorrow.add64(500 * 1e6); // Reduced from 5000 to 500 USDC
    const encB = await encBorrow.encrypt();
    const borrowTx = await this.core.borrow(encB.handles[0], encB.inputProof);
    await borrowTx.wait();

    // Wait for the gateway to process the borrow decryption and callback
    await awaitAllDecryptionResults();

    // Mint 6 000 USDC and approve
    await this.debt.mint(this.signers.alice, 600 * 1e6); // Reduced from 6000 to 600 USDC
    console.log("Test - Balance of Alice:", await this.debt.balanceOf(this.signers.alice));
    await this.debt.connect(this.signers.alice).approve(this.core, 600 * 1e6);

    // Create an encrypted input for the repay amount
    const encRepay = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    encRepay.add64(600 * 1e6);
    const encR = await encRepay.encrypt();

    // Attempt to repay 6 000 USDC
    const repayTx = await this.core.repay(600 * 1e6, encR.handles[0], encR.inputProof);
    await repayTx.wait();
    console.log("Repay transaction completed");

    console.log("Test - Balance of Alice after repay:", await this.debt.balanceOf(this.signers.alice));
    console.log("Alice's debt before repay:", (await debug.decrypt64(await this.core.encryptedDebtOf(this.signers.alice))).toString());

    // Wait for the gateway to process the repay decryption and callback
    console.log("Waiting for decryption results...");
    await awaitAllDecryptionResults();
    console.log("Decryption results received");

    console.log("Test - Balance of Alice after repayCallback:", await this.debt.balanceOf(this.signers.alice));

    // Alice balance should be refunded back to 600
    const balAfter = await this.debt.balanceOf(this.signers.alice);
    console.log("Alice's balance after repay:", balAfter.toString());
    expect(balAfter).to.equal(600 * 1e6);

    // Debt must be 0 after repay
    const debtHandle = await this.core.encryptedDebtOf(this.signers.alice);
    const d = await debug.decrypt64(debtHandle);
    console.log("Alice's debt after repay:", d.toString());
    expect(d).to.equal(0);
  });

  it("DEBUG – hardhat decrypt helpers", async function () {
    if (network.name !== "hardhat") this.skip();

    const handle = await this.core.encryptedDebtOf(this.signers.alice);
    expect(handle).to.equal(0n);
  });
});
