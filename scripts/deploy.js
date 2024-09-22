// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.ethers.run('compile');

  // We get the contract to deploy
  // const WETH9_deploy = await hre.ethers.getContractFactory("WETH9");
  // const WETH9_deployed = await WETH9_deploy.deploy();
  // const WETH9 = await WETH9_deployed.deployed();

  const account = await hre.ethers.getSigner();
  console.log(account.address);

  const v4token_deploy = await hre.ethers.getContractFactory("Detector");
  const v4token_deployed = await v4token_deploy.deploy();
  const v4token = await v4token_deployed.deployed();
  console.log("Detector deployed to:",v4token.address);

  const v4NFT_deploy = await hre.ethers.getContractFactory("BuyContract");
  const v4NFT_deployed = await v4NFT_deploy.deploy();
  const v4NFT = await v4NFT_deployed.deployed();
  console.log("BuyContract deployed to:",v4NFT.address);

  // const FullMigration_deploy = await hre.ethers.getContractFactory("FullMigration");
  // const FullMigration_deployed = await FullMigration_deploy.deploy(account.address);
  // const FullMigration = await FullMigration_deployed.deployed();
  // console.log("FullMigration deployed to:",FullMigration.address);

  // const migrator_boot_strapper = await FullMigration_deployed.getBootstrapper();

  // const ZeroEx_deploy = await hre.ethers.getContractFactory("ZeroEx");
  // const ZeroEx_deployed = await ZeroEx_deploy.deploy(migrator_boot_strapper);
  // const ZeroEx = await ZeroEx_deployed.deployed();
  // console.log("ZeroEx deployed to:",ZeroEx.address);

  // const ERC721OrdersFeature_deploy = await ethers.getContractFactory("ERC721OrdersFeature");
  // const ERC721OrdersFeature_deployed = await ERC721OrdersFeature_deploy.deploy(ZeroEx.address, '0x0a180A76e4466bF68A7F86fB029BEd3cCcFaAac5');
  // const ERC721OrdersFeature = await ERC721OrdersFeature_deployed.deployed();
  // console.log("ERC721OrderFeature deployed to:",ERC721OrdersFeature.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
