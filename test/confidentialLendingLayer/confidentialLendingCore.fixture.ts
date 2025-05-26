import { ethers } from "hardhat";
import { ConfidentialLendingCore } from "../typechain-types";
import { MockERC20 } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

export async function deployConfidentialLendingCoreFixture() {
  const [owner, user, protocolPool] = await ethers.getSigners();

  // Deploy mock tokens
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const underlying = await MockERC20.deploy("Underlying", "UND");
  const collateral = await MockERC20.deploy("Collateral", "COL");

  // Deploy ConfidentialLendingCore
  const ConfidentialLendingCore = await ethers.getContractFactory("ConfidentialLendingCore");
  const confidentialLendingCore = await ConfidentialLendingCore.deploy(
    await underlying.getAddress(),
    await collateral.getAddress(),
    protocolPool.address
  );

  // Mint tokens to user
  await collateral.mint(user.address, ethers.parseEther("10"));
  await underlying.mint(await confidentialLendingCore.getAddress(), ethers.parseEther("1000"));

  return { confidentialLendingCore, underlying, collateral, owner, user, protocolPool };
} 