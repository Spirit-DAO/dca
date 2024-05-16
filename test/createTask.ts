import {
	time,
	loadFixture,
  } from "@nomicfoundation/hardhat-toolbox/network-helpers";
  import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
  import { expect } from "chai";
  import hre from "hardhat";
  import { ethers } from "hardhat";
  const fs = require('fs');
  const path = require('path');
  const deployDataPath = path.resolve(__dirname, '../deploys.json');
	let deploysData = JSON.parse(fs.readFileSync(deployDataPath, 'utf8'));

	const deployExtraDataPath = path.resolve(__dirname, '../deploys_extra.json');
	let deploysExtraData = JSON.parse(fs.readFileSync(deployExtraDataPath, 'utf8'));

  describe("Dca", function () {
	async function deploy() {
		const dcaFactory = await ethers.getContractFactory("SpiritSwapDCA");
		const dca = await dcaFactory.deploy(deploysExtraData.proxy, deploysExtraData.gelato, deploysExtraData.tresory, deploysExtraData.usdc);

		console.log(deploysExtraData.usdc);
		await dca.waitForDeployment();

		return [ dca ];
	}
  
	describe("Test", function () {
	  it("y sait", async function () {
		//const [owner] = await hre.ethers.getSigners();
		const [dca] = await deploy();

		console.log(await dca.test());
		//expect(await dca.usdc).to.equal("0x9FDdA2Eb31bF682E918be4548722B82A7F5705E5");
	  });
	});
  });
  