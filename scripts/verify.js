const hre = require("hardhat");
const fs = require('fs');
const path = require('path');

async function main() {

    const deployDataPath = path.resolve(__dirname, '../deploys.json');
    let deploysData = JSON.parse(fs.readFileSync(deployDataPath, 'utf8'));

	const deployExtraDataPath = path.resolve(__dirname, '../deploys_extra.json');
	let deploysExtraData = JSON.parse(fs.readFileSync(deployExtraDataPath, 'utf8'));

	await hre.run("verify:verify", {
		address: deploysData.dca,
		constructorArguments: [
			deploysExtraData.swapRouter,
			deploysExtraData.gelato,
			deploysExtraData.tresory
		],
	});
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });