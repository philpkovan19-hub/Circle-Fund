const { ethers } = require("hardhat");

async function main() {
  const [signer] = await ethers.getSigners();
  console.log("Deployer:", signer.address);
  const bal = await ethers.provider.getBalance(signer.address);
  console.log("Balance :", ethers.formatEther(bal), "BOT");

  const F = await ethers.getContractFactory("CircleFund");
  const cf = await F.deploy();
  await cf.waitForDeployment();
  const addr = await cf.getAddress();
  console.log("CircleFund deployed at:", addr);
  console.log("\nNext: Update CONTRACT_ADDRESS in frontend/index.html");
}

main().catch((e) => { console.error(e); process.exit(1); });
