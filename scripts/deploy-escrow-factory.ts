import "dotenv/config";
import { network } from "hardhat";
import { getAddress } from "ethers";
import fs from "node:fs";
import path from "node:path";

const POLYGON_CHAIN_ID = 137n;
const MAX_FEE_BPS = 500n;

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`Missing required env var: ${name} (check your .env file)`);
  }
  return value.trim();
}

const WTC = getAddress(requireEnv("WTC"));
const FEE_RECIPIENT = getAddress(requireEnv("FEE_RECIPIENT"));
const FEE_BPS = BigInt(requireEnv("FEE_BPS"));

async function main() {
  if (FEE_BPS < 0n || FEE_BPS > MAX_FEE_BPS) {
    throw new Error(`FEE_BPS must be between 0 and ${MAX_FEE_BPS}, got ${FEE_BPS}`);
  }

  const { ethers } = await network.create();
  const chain = await ethers.provider.getNetwork();
  if (chain.chainId !== POLYGON_CHAIN_ID) {
    throw new Error(
      `Refusing to deploy: expected Polygon chain ID ${POLYGON_CHAIN_ID}, got ${chain.chainId}`,
    );
  }

  const signers = await ethers.getSigners();
  const deployer = signers[0];
  if (!deployer) {
    throw new Error("No deployer account is configured; set PRIVATE_KEY.");
  }

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("deployer:", deployer.address);
  console.log("balance :", ethers.formatEther(balance), "POL");

  if (balance === 0n) {
    throw new Error("Deployer has zero POL — fund the wallet before deploying.");
  }

  console.log("wtc     :", WTC);
  console.log("fee to  :", FEE_RECIPIENT);
  console.log("fee bps :", FEE_BPS.toString());

  const Factory = await ethers.getContractFactory("WealthCoinEscrowFactory");
  const factory = await Factory.deploy(WTC, FEE_RECIPIENT, deployer.address, FEE_BPS);

  console.log("tx      :", factory.deploymentTransaction()?.hash ?? "(pending)");
  await factory.waitForDeployment();

  const address = await factory.getAddress();
  console.log("factory :", address);

  const outDir = path.join(process.cwd(), "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(
    path.join(outDir, "polygon.json"),
    JSON.stringify(
      {
        network: "polygon",
        chainId: Number(chain.chainId),
        factory: address,
        wtc: WTC,
        feeRecipient: FEE_RECIPIENT,
        feeBps: Number(FEE_BPS),
        resolver: deployer.address,
        deployer: deployer.address,
        deployedAt: new Date().toISOString(),
      },
      null,
      2
    )
  );
  console.log("saved   : deployments/polygon.json");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
