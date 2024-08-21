const hre = require("hardhat");
const fs = require('fs');
const path = require('path');

//address _proxy, address _automate, address _tresory

async function main() {
	const deployDataPath = path.resolve(__dirname, '../deploys.json');
	let deploysData = JSON.parse(fs.readFileSync(deployDataPath, 'utf8'));

	const deployExtraDataPath = path.resolve(__dirname, '../deploys_extra.json');
	let deploysExtraData = JSON.parse(fs.readFileSync(deployExtraDataPath, 'utf8'));

	const dcaFactory = await hre.ethers.getContractFactory("SilverSwapDCA");
	
	const dca = await dcaFactory.deploy(deploysExtraData.swapRouter, deploysExtraData.gelato, deploysExtraData.tresory);

	await dca.waitForDeployment();

	deploysData.dca = dca.target;
	console.log(`deployed to ${dca.target}`);
	
	
	fs.writeFileSync(deployDataPath, JSON.stringify(deploysData), 'utf-8');
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
