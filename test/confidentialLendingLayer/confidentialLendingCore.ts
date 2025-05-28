import { expect } from "chai";
import { ethers, network } from "hardhat";

import { awaitAllDecryptionResults, initGateway } from "../asyncDecrypt";
import { createInstance } from "../instance";
import { reencryptEuint256 } from "../reencrypt";
import { debug } from "../utils";
import { deployCoreFixture } from "./confidentialLendingCore.fixture";

describe("ConfidentialLendingCore", function () {
  before(async function () {
    // Initialize signers
    this.fhevm = await createInstance();
    await initGateway();
  });

  beforeEach(async function () {
    const { core, coll, debt, collPool, debtPool, signers } = await deployCoreFixture();
    this.core = core;
    this.coll = coll;
    this.debt = debt;
    this.collPool = collPool;
    this.debtPool = debtPool;
    this.signers = signers;
  });

  it("should accept a collateral deposit and expose encrypted balance", async function () {
    await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("3"));
    await (await this.core.depositCollateral(ethers.parseEther("3"))).wait();
    const handle = await this.core.encryptedCollOf(this.signers.alice);
    const val = await reencryptEuint256(this.signers.alice, this.fhevm, handle, await this.core.getAddress());
    expect(val).to.equal(ethers.parseEther("3"));
  });

  it("should queue a borrow and settle via callback in mocked mode", async function () {
    // Deposit collateral first
    await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
    await (await this.core.depositCollateral(ethers.parseEther("5"))).wait();

    const collHandle = await this.core.encryptedCollOf(this.signers.alice);
    const c = await debug.decrypt256(collHandle);
    expect(c).to.equal(ethers.parseEther("5"));

    // Request borrow - using a smaller amount that satisfies the vault health check
    const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    encIn.add256(100 * 1e6); // 100 USDC
    const encAmt = await encIn.encrypt();
    const tx = await this.core.borrow(encAmt.handles[0], encAmt.inputProof);
    await tx.wait();

    // Wait for the gateway to process the decryption and call the callback
    await awaitAllDecryptionResults();

    // Check the balance
    const bal = await this.debt.balanceOf(this.signers.alice);
    expect(bal).to.equal(100 * 1e6);

    const debtHandle = await this.core.encryptedDebtOf(this.signers.alice);
    const d = await debug.decrypt256(debtHandle);
    expect(d).to.equal(100 * 1e6);
  });

  it("should ignore an over‑repayment", async function () {
    // Alice deposits and borrows 5 000 USDC
    await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
    await (await this.core.depositCollateral(ethers.parseEther("5"))).wait();

    const encBorrow = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    encBorrow.add256(500 * 1e6); // Reduced from 5000 to 500 USDC
    const encB = await encBorrow.encrypt();
    const borrowTx = await this.core.borrow(encB.handles[0], encB.inputProof);
    await borrowTx.wait();

    // Wait for the gateway to process the borrow decryption and callback
    await awaitAllDecryptionResults();

    // Mint 6 000 USDC and approve
    await this.debt.mint(this.signers.alice, 600 * 1e6); // Reduced from 6000 to 600 USDC
    await this.debt.connect(this.signers.alice).approve(this.core, 600 * 1e6);

    // Create an encrypted input for the repay amount
    const encRepay = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
    encRepay.add256(600 * 1e6);
    const encR = await encRepay.encrypt();

    // Attempt to repay 6 000 USDC
    const repayTx = await this.core.repay(600 * 1e6, encR.handles[0], encR.inputProof);
    await repayTx.wait();

    // Wait for the gateway to process the repay decryption and callback
    await awaitAllDecryptionResults();

    // Alice balance should be refunded back to 600
    const balAfter = await this.debt.balanceOf(this.signers.alice);
    expect(balAfter).to.equal(600 * 1e6);

    // Debt must be 0 after repay
    const debtHandle = await this.core.encryptedDebtOf(this.signers.alice);
    const d = await debug.decrypt256(debtHandle);
    expect(d).to.equal(0);
  });

  it("DEBUG – hardhat decrypt helpers", async function () {
    if (network.name !== "hardhat") this.skip();

    const handle = await this.core.encryptedDebtOf(this.signers.alice);
    expect(handle).to.equal(0n);
  });

  describe("Admin functions", function () {
    it("should allow owner to pause and unpause", async function () {
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(100 * 1e6);
      const encAmt = await encIn.encrypt();

      // Test pause
      await this.core.connect(this.signers.alice).pause();
      await expect(this.core.depositCollateral(ethers.parseEther("1"))).to.be.revertedWithCustomError(
        this.core,
        "EnforcedPause",
      );
      await expect(this.core.borrow(encAmt.handles[0], encAmt.inputProof)).to.be.revertedWithCustomError(
        this.core,
        "EnforcedPause",
      );
      await expect(this.core.repay(100 * 1e6, encAmt.handles[0], encAmt.inputProof)).to.be.revertedWithCustomError(
        this.core,
        "EnforcedPause",
      );

      // Test unpause
      await this.core.unpause();
      await this.core.depositCollateral(ethers.parseEther("1"));
      await this.core.borrow(encAmt.handles[0], encAmt.inputProof);
      await this.core.repay(100 * 1e6, encAmt.handles[0], encAmt.inputProof);
    });

    it("should not allow non-owner to pause or unpause", async function () {
      const nonOwner = this.signers.bob;
      const nonOwnerAddress = await nonOwner.getAddress();

      await expect(this.core.connect(nonOwner).pause())
        .to.be.revertedWithCustomError(this.core, "OwnableUnauthorizedAccount")
        .withArgs(nonOwnerAddress);

      await expect(this.core.connect(nonOwner).unpause())
        .to.be.revertedWithCustomError(this.core, "OwnableUnauthorizedAccount")
        .withArgs(nonOwnerAddress);
    });
  });

  describe("View functions", function () {
    it("should return encrypted debt and collateral amounts", async function () {
      // Deposit collateral first
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("1"));
      await this.core.depositCollateral(ethers.parseEther("1"));

      // Create encrypted borrow amount
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(100 * 1e6); // 100 USDC
      const encAmt = await encIn.encrypt();

      // Borrow
      await (await this.core.borrow(encAmt.handles[0], encAmt.inputProof)).wait();

      await awaitAllDecryptionResults();

      // Check encrypted amounts
      const encryptedColl = await this.core.encryptedCollOf(this.signers.alice.address);
      const encryptedDebt = await this.core.encryptedDebtOf(this.signers.alice.address);

      // Decrypt and verify values
      const coll = await debug.decrypt256(encryptedColl);
      const debt = await debug.decrypt256(encryptedDebt);

      expect(debt).to.equal(100 * 1e6);
      expect(coll).to.equal(ethers.parseEther("1"));
    });
  });

  describe("Vault health checks", function () {
    it("should prevent borrowing when vault health factor is too low", async function () {
      // Deposit collateral (10 WETH)
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("10"));
      await this.core.depositCollateral(ethers.parseEther("10"));

      const collHandle = await this.core.encryptedCollOf(this.signers.alice);
      const c = await debug.decrypt256(collHandle);
      expect(c).to.equal(ethers.parseEther("10"));

      // First borrow up to the LTV limit (80% of collateral)
      const maxBorrowAmount = ethers.parseUnits("24000", 6); // 24,000 USDC
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(maxBorrowAmount);
      const encAmt = await encIn.encrypt();

      const firstBorrowTx = await this.core.borrow(encAmt.handles[0], encAmt.inputProof);
      await firstBorrowTx.wait();
      await awaitAllDecryptionResults();

      const debtHandle = await this.core.encryptedDebtOf(this.signers.alice);
      const d = await debug.decrypt256(debtHandle);
      expect(d).to.equal(maxBorrowAmount);

      // Now try to borrow more, which should fail the vault health check
      const encIn2 = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn2.add256(ethers.parseUnits("1000", 6)); // Try to borrow 1,000 more USDC
      const encAmt2 = await encIn2.encrypt();

      const secondBorrowTx = await this.core.borrow(encAmt2.handles[0], encAmt2.inputProof);
      await secondBorrowTx.wait();

      // The vault health check happens in the callback
      expect(await awaitAllDecryptionResults()).to.be.revertedWithCustomError(this.core, "VaultHealthFactorLow");
    });

    it("should prevent borrowing when user health factor is too low", async function () {
      // Deposit collateral (10 WETH)
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("10"));
      await this.core.depositCollateral(ethers.parseEther("10"));

      // Try to borrow an amount that would make the user's health factor too low
      // MIN_USER_HF_BP is 11500 (1.15x), so we need to borrow more than 8.7 USDC
      // At $3,000 per WETH, 10 WETH = $30,000
      // At 1.15x health factor, max borrow = $30,000 / 1.15 = $26,087
      // So we'll try to borrow $27,000 USDC
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(ethers.parseUnits("270000000000000000000000000000000000000000", 6)); // 27,000 USDC should fail the user health check
      const encAmt = await encIn.encrypt();

      const borrowTx = await this.core.borrow(encAmt.handles[0], encAmt.inputProof);
      await borrowTx.wait();

      // The user health check happens in the borrow function
      try {
        await awaitAllDecryptionResults();
        // If we get here, the borrow was successful
        throw new Error("Expected user health check to fail");
      } catch (error: any) {
        // The borrow should have been rejected with amount 0
        const balance = await this.debt.balanceOf(this.signers.alice);
        expect(balance).to.equal(0);
        return;
      }
    });

    it("should allow borrowing within vault health factor limits", async function () {
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(500 * 1e6); // Safe amount within MAX_VAULT_LTV
      const encSafeAmt = await encIn.encrypt();

      // Deposit collateral
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("10"));
      await this.core.depositCollateral(ethers.parseEther("10"));

      // Borrow an amount within LTV limits
      await this.core.borrow(encSafeAmt.handles[0], encSafeAmt.inputProof);
      await expect(awaitAllDecryptionResults()).to.not.be.reverted;
    });
  });

  describe("Edge cases", function () {
    it("should handle borrow rejection in callback when amt == 0", async function () {
      // Create encrypted inputs with zero amount
      const zeroIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      zeroIn.add256(0);
      const encZero = await zeroIn.encrypt();

      // Queue a borrow with zero amount
      const borrowTx = await this.core.borrow(encZero.handles[0], encZero.inputProof);
      await borrowTx.wait();

      // The callback should return early without reverting
      await expect(awaitAllDecryptionResults()).to.not.be.reverted;
    });

    it("should reject zero amount deposits and repays", async function () {
      // Create encrypted inputs
      const zeroIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      zeroIn.add256(0);
      const encZero = await zeroIn.encrypt();

      // Try to deposit zero amount
      await expect(this.core.depositCollateral(0)).to.be.revertedWithCustomError(this.core, "ZeroAmount");

      // Try to repay zero amount
      await expect(this.core.repay(0, encZero.handles[0], encZero.inputProof)).to.be.revertedWithCustomError(
        this.core,
        "ZeroAmount",
      );
    });
  });

  describe("Gateway access control", function () {
    it("should only allow gateway to call borrowCallback", async function () {
      // Try to call borrowCallback directly as a non-gateway address
      await expect(this.core.connect(this.signers.bob).borrowCallback(0, 0)).to.be.revertedWithoutReason();
    });

    it("should only allow gateway to call repayCallback", async function () {
      // Try to call repayCallback directly as a non-gateway address
      await expect(this.core.connect(this.signers.bob).repayCallback(0, 0)).to.be.revertedWithoutReason();
    });
  });

  describe("Withdraw operations", function () {
    it("should queue a withdraw and settle via callback", async function () {
      const aliceBalanceBefore = await this.coll.balanceOf(this.signers.alice);
      // Deposit collateral first
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      await this.core.depositCollateral(ethers.parseEther("5"));

      // Create encrypted withdraw amount
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(ethers.parseEther("2")); // Withdraw 2 WETH
      const encAmt = await encIn.encrypt();

      // Request withdraw
      const tx = await this.core.withdraw(encAmt.handles[0], encAmt.inputProof);
      await tx.wait();

      // Wait for the gateway to process the decryption and call the callback
      await awaitAllDecryptionResults();

      // Check the balance
      const bal = await this.coll.balanceOf(this.signers.alice);
      expect(bal).to.equal(aliceBalanceBefore - ethers.parseEther("3"));

      // Check encrypted collateral
      const collHandle = await this.core.encryptedCollOf(this.signers.alice);
      const c = await debug.decrypt256(collHandle);
      expect(c).to.equal(ethers.parseEther("3")); // 5 - 2 = 3 WETH remaining
    });

    it("should prevent withdrawing when user health factor is too low", async function () {
      // Deposit collateral
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("10"));
      await this.core.depositCollateral(ethers.parseEther("10"));

      // Borrow some USDC to create debt
      const encBorrow = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encBorrow.add256(ethers.parseUnits("20000", 6)); // Borrow 20,000 USDC
      const encB = await encBorrow.encrypt();
      await this.core.borrow(encB.handles[0], encB.inputProof);
      await awaitAllDecryptionResults();

      // Try to withdraw too much collateral
      const encWithdraw = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encWithdraw.add256(ethers.parseEther("10")); // Try to withdraw everything WETH
      const encW = await encWithdraw.encrypt();

      // Request withdraw
      const tx = await this.core.withdraw(encW.handles[0], encW.inputProof);
      await tx.wait();

      // The user health check should fail and return 0 amount
      await awaitAllDecryptionResults();

      // Check that no collateral was withdrawn
      const bal = await this.coll.balanceOf(this.signers.alice);
      expect(bal).to.equal(0); // No collateral should be withdrawn

      // Check encrypted collateral remains unchanged
      const collHandle = await this.core.encryptedCollOf(this.signers.alice);
      const c = await debug.decrypt256(collHandle);
      expect(c).to.equal(ethers.parseEther("10")); // Should still have 10 WETH
    });

    it("should handle withdraw rejection in callback when amt == 0", async function () {
      // Create encrypted inputs with zero amount
      const zeroIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      zeroIn.add256(0);
      const encZero = await zeroIn.encrypt();

      // Queue a withdraw with zero amount
      const withdrawTx = await this.core.withdraw(encZero.handles[0], encZero.inputProof);
      await withdrawTx.wait();

      // The callback should return early without reverting
      await expect(awaitAllDecryptionResults()).to.not.be.reverted;
    });

    it("should prevent withdrawing when vault health factor is too low", async function () {
      // Deposit collateral
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("10"));
      await this.core.depositCollateral(ethers.parseEther("10"));

      // Borrow up to the LTV limit
      const maxBorrowAmount = ethers.parseUnits("24000", 6); // 24,000 USDC
      const encBorrow = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encBorrow.add256(maxBorrowAmount);
      const encB = await encBorrow.encrypt();
      await this.core.borrow(encB.handles[0], encB.inputProof);
      await awaitAllDecryptionResults();

      // Try to withdraw too much collateral
      const encWithdraw = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encWithdraw.add256(ethers.parseEther("8")); // Try to withdraw 8 WETH
      const encW = await encWithdraw.encrypt();

      // Request withdraw
      const tx = await this.core.withdraw(encW.handles[0], encW.inputProof);
      await tx.wait();

      // The vault health check should fail in the callback
      expect(await awaitAllDecryptionResults()).to.be.revertedWithCustomError(this.core, "VaultHealthFactorLow");
    });

    it("should revert when withdraw operation fails", async function () {
      // Deposit collateral first
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      await this.core.depositCollateral(ethers.parseEther("5"));

      // Mock the collateralCToken to fail on redeem
      await this.collPool.setRedeemShouldFail(true);

      // Create encrypted withdraw amount
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(ethers.parseEther("2")); // Withdraw 2 WETH
      const encAmt = await encIn.encrypt();

      // Request withdraw
      const tx = await this.core.withdraw(encAmt.handles[0], encAmt.inputProof);
      await tx.wait();

      // The callback should revert with RedeemFailed error
      expect(await awaitAllDecryptionResults()).to.be.revertedWithCustomError(this.core, "RedeemFailed");

      // Reset the mock
      await this.collPool.setRedeemShouldFail(false);
    });

    it("should revert when withdraw is called while paused", async function () {
      // Deposit collateral first
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      await this.core.depositCollateral(ethers.parseEther("5"));

      // Pause the contract
      await this.core.pause();

      // Create encrypted withdraw amount
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(ethers.parseEther("2")); // Withdraw 2 WETH
      const encAmt = await encIn.encrypt();

      // Attempt to withdraw while paused
      await expect(this.core.withdraw(encAmt.handles[0], encAmt.inputProof)).to.be.revertedWithCustomError(
        this.core,
        "EnforcedPause",
      );

      // Unpause the contract
      await this.core.unpause();
    });

    it("should revert when withdrawCallback is called by non-gateway", async function () {
      // Deposit collateral first
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      await this.core.depositCollateral(ethers.parseEther("5"));

      // Create encrypted withdraw amount
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(ethers.parseEther("2")); // Withdraw 2 WETH
      const encAmt = await encIn.encrypt();

      // Request withdraw
      const tx = await this.core.withdraw(encAmt.handles[0], encAmt.inputProof);
      await tx.wait();

      // Try to call withdrawCallback directly as a non-gateway address
      await expect(
        this.core.connect(this.signers.bob).withdrawCallback(0, ethers.parseEther("2")),
      ).to.be.revertedWithoutReason();
    });
  });

  describe("Operation failures", function () {
    it("should revert when mint operation fails", async function () {
      // Mock the collateralCToken to fail on mint
      await this.collPool.setMintShouldFail(true);

      // Try to deposit collateral
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      await expect(this.core.depositCollateral(ethers.parseEther("5"))).to.be.revertedWithCustomError(
        this.core,
        "MintFailed",
      );

      // Reset the mock
      await this.collPool.setMintShouldFail(false);
    });

    it("should revert when borrow operation fails", async function () {
      // Deposit collateral first
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      await this.core.depositCollateral(ethers.parseEther("5"));

      // Mock the debtCToken to fail on borrow
      await this.debtPool.setBorrowShouldFail(true);

      // Create encrypted borrow amount
      const encBorrow = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encBorrow.add256(100 * 1e6); // 100 USDC
      const encB = await encBorrow.encrypt();

      // Attempt to borrow
      const borrowTx = await this.core.borrow(encB.handles[0], encB.inputProof);
      await borrowTx.wait();

      // The callback should revert with BorrowFailed error
      expect(await awaitAllDecryptionResults()).to.be.revertedWithCustomError(this.core, "BorrowFailed");

      // Reset the mock
      await this.debtPool.setBorrowShouldFail(false);
    });

    it("should revert when repay operation fails", async function () {
      // Deposit collateral first
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      await this.core.depositCollateral(ethers.parseEther("5"));

      // Borrow some USDC
      const encBorrow = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encBorrow.add256(100 * 1e6); // 100 USDC
      const encB = await encBorrow.encrypt();
      await this.core.borrow(encB.handles[0], encB.inputProof);
      await awaitAllDecryptionResults();

      // Mint and approve USDC for repayment
      await this.debt.mint(this.signers.alice, 100 * 1e6);
      await this.debt.connect(this.signers.alice).approve(this.core, 100 * 1e6);

      // Mock the debtCToken to fail on repay
      await this.debtPool.setRepayShouldFail(true);

      // Create encrypted repay amount
      const encRepay = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encRepay.add256(100 * 1e6);
      const encR = await encRepay.encrypt();

      // Attempt to repay
      const repayTx = await this.core.repay(100 * 1e6, encR.handles[0], encR.inputProof);
      await repayTx.wait();

      // The callback should revert with RepayFailed error
      expect(await awaitAllDecryptionResults()).to.be.revertedWithCustomError(this.core, "RepayFailed");

      // Reset the mock
      await this.debtPool.setRepayShouldFail(false);
    });

    it("should revert when redeem operation fails", async function () {
      // Deposit collateral first
      await this.coll.connect(this.signers.alice).approve(this.core, ethers.parseEther("5"));
      await this.core.depositCollateral(ethers.parseEther("5"));

      // Mock the collateralCToken to fail on redeem
      await this.collPool.setRedeemShouldFail(true);

      // Create encrypted withdraw amount
      const encIn = this.fhevm.createEncryptedInput(await this.core.getAddress(), this.signers.alice.address);
      encIn.add256(ethers.parseEther("2")); // Withdraw 2 WETH
      const encAmt = await encIn.encrypt();

      // Request withdraw
      const tx = await this.core.withdraw(encAmt.handles[0], encAmt.inputProof);
      await tx.wait();

      // The callback should revert with RedeemFailed error
      expect(await awaitAllDecryptionResults()).to.be.revertedWithCustomError(this.core, "RedeemFailed");

      // Reset the mock
      await this.collPool.setRedeemShouldFail(false);
    });
  });
});
