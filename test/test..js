const { expect , assert } = require("chai");
const { ethers, network } = require("hardhat");
require('dotenv').config();

describe("StakingManagerV3", function () {
  let StakingManagerV3, stakingManager;
  let owner, addr1, addr2;
  let stakeToken, rewardToken;

  beforeEach(async function () {
    // Get the ContractFactory and Signers here.
    [owner, addr1, addr2] = await ethers.getSigners();

    // Deploy mock ERC20 tokens for staking and rewards
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    stakeToken = await ERC20Mock.deploy("Stake Token", "STK", owner.address, ethers.utils.parseEther("1000"));
    rewardToken = await ERC20Mock.deploy("Reward Token", "RWD", owner.address, ethers.utils.parseEther("1000"));

    // Deploy the StakingManagerV3 contract
    StakingManagerV3 = await ethers.getContractFactory("StakingManagerV3");
    stakingManager = await StakingManagerV3.deploy();
    await stakingManager.initialize(stakeToken.address, owner.address, rewardToken.address);
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await stakingManager.owner()).to.equal(owner.address);
    });

    it("Should set the correct stake and reward tokens", async function () {
      expect(await stakingManager.stakeToken()).to.equal(stakeToken.address);
      expect(await stakingManager.rewardToken()).to.equal(rewardToken.address);
    });
  });

  describe("Staking", function () {
    it("Should allow users to deposit tokens", async function () {
      await stakeToken.connect(owner).transfer(addr1.address, ethers.utils.parseEther("100"));
      await stakeToken.connect(addr1).approve(stakingManager.address, ethers.utils.parseEther("100"));

      await expect(stakingManager.connect(addr1).deposit(ethers.utils.parseEther("50")))
        .to.emit(stakingManager, "Deposit")
        .withArgs(addr1.address, ethers.utils.parseEther("50"));

      expect(await stakeToken.balanceOf(stakingManager.address)).to.equal(ethers.utils.parseEther("50"));
    });

    it("Should allow users to unstake tokens", async function () {
      await stakeToken.connect(owner).transfer(addr1.address, ethers.utils.parseEther("100"));
      await stakeToken.connect(addr1).approve(stakingManager.address, ethers.utils.parseEther("100"));
      await stakingManager.connect(addr1).deposit(ethers.utils.parseEther("50"));

      await expect(stakingManager.connect(addr1).unstake())
        .to.emit(stakingManager, "Withdraw")
        .withArgs(addr1.address, ethers.utils.parseEther("50"));

      expect(await stakeToken.balanceOf(addr1.address)).to.equal(ethers.utils.parseEther("100"));
    });
  });

  describe("Reward Distribution", function () {
    it("Should distribute rewards correctly after an epoch", async function () {
      // Transfer and approve tokens for staking
      await stakeToken.connect(owner).transfer(addr1.address, ethers.utils.parseEther("100"));
      await stakeToken.connect(addr1).approve(stakingManager.address, ethers.utils.parseEther("100"));
      await stakingManager.connect(addr1).deposit(ethers.utils.parseEther("50"));
  
      // Approve the reward tokens for the staking manager contract
      const rewardAmount = ethers.utils.parseEther("10");
      await rewardToken.connect(owner).approve(stakingManager.address, rewardAmount);
  
      // Start a new epoch
      const startTime = (await ethers.provider.getBlock('latest')).timestamp + 10;
      const endTime = startTime + 100;
      await stakingManager.startEpoch(startTime, endTime, rewardAmount);
  
      // Fast forward time to after the epoch ends
      await ethers.provider.send("evm_increaseTime", [110]);
      await ethers.provider.send("evm_mine");
      // Distribute rewards
      await stakingManager.connect(owner).distribute();

      // Check rewards
      const rewards = await stakingManager.connect(addr1).seeReward(1);
      expect(rewards).to.be.gt(0);
    });
  });

  describe("Epoch Management", function () {
    it("Should start a new epoch correctly", async function () {
      // Approve the reward tokens for the staking manager contract
      const rewardAmount = ethers.utils.parseEther("10");
      await rewardToken.connect(owner).approve(stakingManager.address, rewardAmount);
  
      // Start a new epoch
      const startTime = (await ethers.provider.getBlock('latest')).timestamp + 10;
      const endTime = startTime + 100;
  
      await expect(stakingManager.startEpoch(startTime, endTime, rewardAmount))
        .to.emit(stakingManager, "EpochStarted")
        .withArgs(0, startTime, endTime, rewardAmount);
  
      const epochInfo = await stakingManager.epochInfos(0);
      expect(epochInfo.startTime).to.equal(startTime);
      expect(epochInfo.endTime).to.equal(endTime);
    });
  
    it("Should not allow starting an epoch with invalid parameters", async function () {
      const startTime = (await ethers.provider.getBlock('latest')).timestamp + 10;
      const endTime = startTime - 100; // Invalid end time
      const rewardAmount = ethers.utils.parseEther("10");
  
      await expect(stakingManager.startEpoch(startTime, endTime, rewardAmount))
        .to.be.revertedWith("End time must be after start time");
    });
  });

  describe("Claiming Rewards", function () {
    it("Should allow users to claim their rewards", async function () {
      // Transfer and approve tokens for staking
      await stakeToken.connect(owner).transfer(addr1.address, ethers.utils.parseEther("100"));
      await stakeToken.connect(addr1).approve(stakingManager.address, ethers.utils.parseEther("100"));
      await stakingManager.connect(addr1).deposit(ethers.utils.parseEther("50"));
  
      // Approve the reward tokens for the staking manager contract
      const rewardAmount = ethers.utils.parseEther("10");
      await rewardToken.connect(owner).approve(stakingManager.address, ethers.utils.parseEther("100"));
  
      // Deposit reward tokens into the staking manager contract
      await stakingManager.depositReward(rewardAmount);
  
      // Start a new epoch
      const startTime = (await ethers.provider.getBlock('latest')).timestamp + 10;
      const endTime = startTime + 100;
      await stakingManager.startEpoch(startTime, endTime, rewardAmount);
  
      // Fast forward time to after the epoch ends
      await ethers.provider.send("evm_increaseTime", [110]);
      await ethers.provider.send("evm_mine");
  
      // Distribute rewards
      await stakingManager.distribute();
  
      // Claim rewards
      await expect(stakingManager.connect(addr1).claim(1))
        .to.emit(stakingManager, "HarvestRewards")
        .withArgs(addr1.address, ethers.utils.parseEther("20"));
    });
  });

});
