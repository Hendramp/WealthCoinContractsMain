import "dotenv/config";
import { defineConfig } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import hardhatIgnition from "@nomicfoundation/hardhat-ignition";

export default defineConfig({
  solidity: "0.8.24",
  plugins: [hardhatEthers, hardhatVerify, hardhatIgnition],
  networks: process.env.POLYGON_RPC_URL
    ? {
        polygon: {
          type: "http",
          url: process.env.POLYGON_RPC_URL,
          accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
        },
      }
    : {},
});
