import { ethers } from "hardhat";

import { getSigners } from "../signers";

export async function deployCoreFixture() {
  const signers = await getSigners();

  // ── Deploy mock ERC‑20 tokens ─────────────────────────────────────────
  const ERC20 = await ethers.getContractFactory("MockERC20");
  const coll = await ERC20.deploy("Wrapped Ether", "WETH");
  const debt = await ERC20.deploy("USD Coin", "USDC");

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
