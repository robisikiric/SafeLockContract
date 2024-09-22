// SPDX-License-Identifier: Proprietary

/*************************************************
 * Copyright 2024 Immuni Software PTE Ltd. All rights reserved.
 *
 * This code is proprietary and confidential. Unauthorized copying, 
 * modification, or distribution of this file, via any medium, 
 * is strictly prohibited without prior written consent from 
 * Immuni Software PTE Ltd.
 *************************************************/

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFlashLoanReceiver {
    function receiveFlashLoan(uint256 amount, bytes calldata data) external;
}

contract SafeLock is ReentrancyGuard {
    IERC20 public immutable sharesToken; // The token users deposit (VAULT token)
    uint64 public constant MAX_REWARD = 1 ether; // Reward issued on max lock duration
    uint256 public constant MIN_LOCK_DURATION = 365 days; // Minimum lock duration (1 year)
    uint256 public constant MAX_LOCK_DURATION = 5 * 365 days; // Maximum lock duration (5 years)
    uint256 public constant FLASHLOAN_FEE = 0.001 ether; // Fixed fee for flash loan
    uint256 public totalLockedShares; // Total shares currently locked
    uint256 public totalRewards; // Total ETH rewards distributed

    struct User {
        uint256 balance; // Amount of shares deposited by the user
        uint32 expiry; // Expiry timestamp when shares can be withdrawn
        uint32 duration; // Duration of lock
    }

    mapping(address => User) public users;

    event SharesDeposited(address indexed user, uint256 amount, uint256 expiry);
    event SharesWithdrawn(
        address indexed user,
        uint256 amount,
        uint256 rewards
    );
    event RewardDistributed(uint256 amount);
    event FlashLoan(address indexed borrower, uint256 amount);

    constructor(IERC20 _sharesToken) {
        sharesToken = _sharesToken;
    }

    modifier onlyOneActiveLock() {
        require(
            users[msg.sender].balance == 0,
            "User already has an active lock"
        );
        _;
    }

    /**
     * @notice Deposit shares into the vault and lock them for a user-defined duration
     * @param amount The number of shares to deposit
     * @param lockDuration The duration (in seconds) for which the shares will be locked
     */
    function deposit(
        uint256 amount,
        uint32 lockDuration
    ) external nonReentrant onlyOneActiveLock {
        require(amount > 0, "Cannot deposit 0 shares");
        require(
            lockDuration >= MIN_LOCK_DURATION &&
                lockDuration <= MAX_LOCK_DURATION,
            "Invalid lock duration"
        );

        User memory user = users[msg.sender];
        uint32 expiry = uint32(block.timestamp) + lockDuration;

        // Transfer shares from the user to this contract
        require(
            sharesToken.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        // Update user's locked balance and expiry
        user.balance += amount;
        user.expiry = expiry;
        user.duration = lockDuration;
        users[msg.sender] = user;

        // Update total locked shares
        totalLockedShares += amount;

        emit SharesDeposited(msg.sender, amount, expiry);
    }

    /**
     * @notice Withdraw shares along with proportional ETH rewards
     */
    function withdraw() external nonReentrant {
        User memory user = users[msg.sender];
        require(block.timestamp >= user.expiry, "Shares are still locked");
        require(user.balance > 0, "No shares to withdraw");

        uint256 amount = user.balance;
        uint256 rewards = calculateRewards(msg.sender);

        // Update total locked shares
        totalLockedShares -= amount;

        require(
            sharesToken.transfer(msg.sender, amount),
            "Transfer of shares failed"
        );
        if (rewards > 0) payable(msg.sender).transfer(rewards);

        // Reset user's balance and expiry
        user.balance = 0;
        user.expiry = 0;
        user.duration = 0;

        users[msg.sender] = user;

        emit SharesWithdrawn(msg.sender, amount, rewards);
    }

    /**
     * @notice Distribute ETH rewards to the staking contract
     */
    function distributeRewards() external payable {
        require(msg.value > 0, "Must send ETH to distribute rewards");
        totalRewards += msg.value;

        emit RewardDistributed(msg.value);
    }

    /**
     * @notice Calculate the rewards for a user based on the duration of locking
     * @param userAddress The address of the user
     * @return rewards The calculated rewards for the user
     */
    function calculateRewards(
        address userAddress
    ) public view returns (uint256) {
        User storage user = users[userAddress];
        if (totalLockedShares == 0 || user.balance == 0) {
            return 0;
        }
        return ((MAX_REWARD * user.duration) / MAX_LOCK_DURATION);
    }

    /**
     * @notice Flash loan function allowing anyone to borrow shares
     * @param amount The number of shares to borrow
     * @param data Extra data to pass to the borrower for callback
     */
    function flashLoan(
        uint256 amount,
        bytes calldata data
    ) external payable nonReentrant {
        require(msg.value >= FLASHLOAN_FEE, "Incorrect fee amount");
        require(amount > 0, "Cannot borrow 0 shares");
        require(totalLockedShares >= amount, "Insufficient shares available");

        // Transfer shares to the borrower
        require(sharesToken.transfer(msg.sender, amount), "Transfer failed");

        // Trigger callback to borrower with borrowed shares
        IFlashLoanReceiver(msg.sender).receiveFlashLoan(amount, data);

        // Ensure the borrower returns the shares
        require(
            sharesToken.balanceOf(address(this)) >= totalLockedShares,
            "Flash loan not repaid"
        );

        emit FlashLoan(msg.sender, amount);
    }

    /**
     * @notice collect flashloan fee
     * @param amount The amount of ETH to withdraw
     */
    function collectFlashloanFee(uint256 amount) external {
        require(amount <= address(this).balance, "Insufficient balance");
        payable(msg.sender).transfer(amount);
        require(totalRewards <= address(this).balance, "Insufficient balance");
    }

    receive() external payable {}
}