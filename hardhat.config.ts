import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
const path = require('path');
const env_config = require('dotenv').config({ path: path.resolve(__dirname, '.env') });
const { PRIVATE_KEY, FANTOM_KEY } = env_config.parsed || {};

const config: HardhatUserConfig = {
  solidity: {
	version:"0.8.20",
	settings: {
		evmVersion: "paris",
		optimizer: {
			enabled: true,
			runs: 200
		},
		viaIR: true,
	},
  },
  networks: {
	fantom: {
		url: "https://rpc.ankr.com/fantom",
		chainId: 250,
		accounts: [`${PRIVATE_KEY}`],
		gasPrice: 58000000000,
	},
	tenderly: {
		url: "https://rpc.tenderly.co/fork/4cd14cfd-4036-4cd6-a8ff-bc6c8163fc44",
		chainId: 250,
		accounts: [`${PRIVATE_KEY}`],
		gasPrice: 58000000000,
	},
	ftmtest: {
		url: "https://rpc.testnet.fantom.network/",
		chainId: 4002,
		accounts: [PRIVATE_KEY],
	},
	},
	etherscan: {
        apiKey: {
            opera: FANTOM_KEY,
			ftmTestnet: FANTOM_KEY,
        },
    },
};

export default config;
