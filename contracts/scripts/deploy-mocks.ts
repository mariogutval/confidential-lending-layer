import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy Mock WETH
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const weth = await MockERC20.deploy("Wrapped Ether", "WETH");
  await weth.waitForDeployment();
  console.log("Mock WETH deployed to:", await weth.getAddress());

  // Deploy Mock USDC
  const usdc = await MockERC20.deploy("USD Coin", "USDC");
  await usdc.waitForDeployment();
  console.log("Mock USDC deployed to:", await usdc.getAddress());

  // Deploy MockCompoundPool cWETH
  const MockCompoundPool = await ethers.getContractFactory("MockCompoundPool");
  const collPool = await MockCompoundPool.deploy(await weth.getAddress());
  await collPool.waitForDeployment();
  console.log("MockCompoundPool cWETH deployed to:", await collPool.getAddress());

  // Deploy MockCompoundPool cUSDC
  const debtPool = await MockCompoundPool.deploy(await usdc.getAddress());
  await debtPool.waitForDeployment();
  console.log("MockCompoundPool cUSDC deployed to:", await debtPool.getAddress());

  // Deploy ConfidentialLendingCore
  const ConfidentialLendingCore = await ethers.getContractFactory("ConfidentialLendingCore");
  const lendingCore = await ConfidentialLendingCore.deploy(
    await weth.getAddress(),
    await usdc.getAddress(),
    await collPool.getAddress(),
    await debtPool.getAddress()
  );
  await lendingCore.waitForDeployment();
  console.log("ConfidentialLendingCore deployed to:", await lendingCore.getAddress());

  // Mint some tokens to the deployer
  const wethAmount = ethers.parseEther("10"); // 10 WETH
  const usdcAmount = ethers.parseUnits("1000", 6); // 1000 USDC

  await weth.mint(deployer.address, wethAmount);
  await usdc.mint(deployer.address, usdcAmount);

  console.log("Minted tokens to deployer:");
  console.log("WETH balance:", ethers.formatEther(await weth.balanceOf(deployer.address)));
  console.log("USDC balance:", ethers.formatUnits(await usdc.balanceOf(deployer.address), 6));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 