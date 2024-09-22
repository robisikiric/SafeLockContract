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

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract SafestVault is ERC20, Ownable, IERC3156FlashLender {
    uint256 public constant MINIMUM_SHARES = 1000; //Minimum shares to burn on first deposit

    IERC20 public immutable underlyingToken; // Immunefi Token
    ISwapRouter public immutable swapRouter;
    IWETH9 public immutable weth;
    IUniswapV3Factory public immutable uniswapFactory;

    uint256 public flashLoanFee = 0; // Fee as a percentage in basis points (e.g., 100 = 1%)
    //map tokens to their Chainlink price feeds.
    mapping(address => AggregatorV3Interface) public priceFeeds;

    //User Account structure for balance and swap preference
    struct UserAccount {
        mapping(address => uint256) balances; // User balances for each address
        bool swapOn; // Boolean flag to enable or disable swapping
    }

    // Mapping to store UserAccount structs for each user
    mapping(address => UserAccount) private _userAccounts;
    uint256 private _totalAssets;

    event Deposit(
        address indexed sender,
        address indexed receiver,
        uint256 indexed amountInUnderlying,
        uint256 shares
    );
    event Withdraw(
        address indexed receiver,
        address indexed owner,
        uint256 indexed amountInUnderlying,
        uint256 shares
    );

    constructor(
        IERC20 _underlyingToken,
        ISwapRouter _swapRouter,
        IWETH9 _weth,
        AggregatorV3Interface _priceFeedUnderlying,
        IUniswapV3Factory _uniswapFactory
    ) ERC20("Vault Token", "VAULT") Ownable(msg.sender) {
        underlyingToken = _underlyingToken;
        swapRouter = _swapRouter;
        weth = _weth;
        priceFeeds[address(_underlyingToken)] = _priceFeedUnderlying;
        uniswapFactory = _uniswapFactory;
    }

    receive() external payable {
        // Accept ETH deposits
        deposit(address(0), msg.value, msg.sender);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    ///                                     PUBLIC FUNCTIONS                                         ///
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Activates a one-time flag to ensure the user's assets are automatically swapped to the underlying asset during deposits.
     */
    function alwaysUnderlying() public {
        if (!_userAccounts[msg.sender].swapOn && (balanceOf(msg.sender) == 0))
            _userAccounts[msg.sender].swapOn = true;
    }

    /**
     * @notice If the user's `swapOn` flag is true, the deposited token will be automatically swapped to the underlying asset.
     * @param token The address of the token to be deposited. Use address(0) for ETH.
     * @param amount The amount of the token to be deposited.
     * @param receiver The address that will receive the shares corresponding to the deposit.
     * @return shares The amount of shares minted to the receiver in exchange for the deposited tokens.
     */
    function deposit(
        address token,
        uint256 amount,
        address receiver
    ) public payable returns (uint256 shares) {
        return _internalDeposit(token, amount, msg.sender, receiver);
    }

    function depositWithPermit(
        address token,
        uint256 amount,
        address owner,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable returns (uint256 shares) {
        IERC20Permit(token).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
        return _internalDeposit(token, amount, owner, receiver);
    }

    function withdraw(
        address token,
        uint256 shares,
        address receiver
    ) external returns (uint256 amountInUnderlying) {
        return _internalWithdraw(token, shares, receiver, msg.sender);
    }

    // Flash loan functionality
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        uint256 fee = flashFee(address(token), amount);
        uint256 balance_before = underlyingToken.balanceOf(address(this));
        underlyingToken.transfer(address(receiver), amount);

        bytes32 CALLBACK_SUCCESS = keccak256(
            "ERC3156FlashBorrower.onFlashLoan"
        );
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) ==
                CALLBACK_SUCCESS,
            "Callback failed"
        );

        uint256 fee_received = underlyingToken.balanceOf(address(this)) -
            balance_before;

        require(fee_received >= fee, "Flash loan not repaid");
        _totalAssets += fee_received;
        return true;
    }

    function setFlashLoanFee(uint256 _flashLoanFee) external onlyOwner {
        require(_flashLoanFee <= 1000, "Fee exceeds 10%");
        flashLoanFee = _flashLoanFee;
    }

    function setPriceFeed(
        address token,
        AggregatorV3Interface priceFeed
    ) external onlyOwner {
        priceFeeds[token] = priceFeed;
    }

    function emergencyWithdraw(
        IERC20 token,
        uint256 amount
    ) external onlyOwner {
        require(token != underlyingToken, "Cannot withdraw underlying token");
        token.transfer(owner(), amount);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    ///                                   INTERNAL FUNCTIONS                                         ///
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    function _internalDeposit(
        address token,
        uint256 amount,
        address sender,
        address receiver
    ) internal returns (uint256 shares) {
        uint256 amountInUnderlying;
        UserAccount storage userAccount = _userAccounts[receiver];
        bool swapOn = userAccount.swapOn;

        if (token == address(0)) {
            // ETH deposit
            require(msg.value == amount, "Incorrect ETH amount sent");
            _handleETHDeposit(amount);
            uint256 amountInWETH = weth.balanceOf(address(this));

            if (swapOn) {
                amountInUnderlying = _swapTokenForUnderlying(
                    address(weth),
                    amountInWETH
                );
                token = address(underlyingToken);
            } else {
                uint256 price = _getOraclePrice(address(weth));
                amountInUnderlying = (amount * (price)) / (1e18);
            }
        } else if (token == address(underlyingToken)) {
            underlyingToken.transferFrom(sender, address(this), amount);
            amountInUnderlying = amount;
        } else {
            // ERC20 token deposit
            IERC20(token).transferFrom(sender, address(this), amount);

            if (swapOn) {
                amountInUnderlying = _swapTokenForUnderlying(token, amount);
                token = address(underlyingToken);
            } else {
                uint256 price = _getOraclePrice(token);
                amountInUnderlying = (amount * (price)) / (1e18);
            }
        }
        shares = _mintShares(amountInUnderlying, receiver);
        userAccount.balances[token] += (
            swapOn ? amountInUnderlying : amount
        ); // Update user balance
        emit Deposit(sender, receiver, amountInUnderlying, shares);
        
    }

    function _internalWithdraw(
        address token,
        uint256 shares,
        address owner,
        address receiver
    ) internal returns (uint256 amountInUnderlying) {
        require(balanceOf(owner) >= shares, "Insufficient shares");
        amountInUnderlying = (shares * (_totalAssets)) / totalSupply();
        _totalAssets -= amountInUnderlying;
        _burnShares(shares, owner);

        UserAccount storage userAccount = _userAccounts[owner];
        bool swapOn = userAccount.swapOn;

        uint256 amountInOriginalToken;
        if (swapOn) {
            if (token == address(underlyingToken)) {
                underlyingToken.transfer(receiver, amountInUnderlying);
            } else {
                revert("Invalid token for withdrawal when swapOn is true");
            }
        } else {
            uint256 price;
            if (token == address(0)) {
                price = _getOraclePrice(address(weth)); 
                amountInOriginalToken = (amountInUnderlying * 1e18) / (price); 
                _handleETHWithdrawal(amountInOriginalToken);
            } else if (token == address(underlyingToken)) {
                // Underlying token withdrawal
                underlyingToken.transfer(receiver, amountInUnderlying);
            } else {
                // ERC20 token withdrawal (calculate amount based on Chainlink oracle)
                price = _getOraclePrice(token); 
                amountInOriginalToken = (amountInUnderlying * 1e18) / (price); 
                IERC20(token).transfer(receiver, amountInOriginalToken);
            }
        }
        _userAccounts[owner].balances[token] -=
            (swapOn ? amountInUnderlying : amountInOriginalToken); // Update user balance
        emit Withdraw(receiver, owner, amountInUnderlying, shares);
    }

    function _swapTokenForUnderlying(
        address token,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        IERC20(token).approve(address(swapRouter), amountIn);
        uint256 estimatedAmountOut = _getEstimatedAmountOut(token, amountIn);
        uint256 minAmountOut = (estimatedAmountOut * (95)) / (100);

        // Create the Uniswap swap parameters
        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: abi.encodePacked(
                    token,
                    uint24(3000),
                    address(underlyingToken)
                ),
                recipient: address(this),
                deadline: block.timestamp + 15,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut // Set minimum amount as 95% of estimated amount
            });

        // Execute the swap
        amountOut = swapRouter.exactInput(params);
    }

    function _mintShares(
        uint256 amount,
        address receiver
    ) internal returns (uint256 shares) {
        uint256 totalSupplyBefore = totalSupply();
        if (totalSupplyBefore == 0) {
            shares = amount - MINIMUM_SHARES;
        } else {
            shares = (amount * (totalSupplyBefore)) / (_totalAssets);
        }

        _mint(receiver, shares);
        _totalAssets += amount; // Update totalAssets
        return shares;
    }

    function _burnShares(
        uint256 shares,
        address owner
    ) public {
        _burn(owner, shares);
        if (balanceOf(owner) == 0) delete _userAccounts[owner];
    }

    function _handleETHDeposit(uint256 amount) internal {
        weth.deposit{value: amount}();
    }

    function _handleETHWithdrawal(uint256 amount) internal {
        weth.withdraw(amount);
        payable(msg.sender).transfer(amount);
    }

    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function maxFlashLoan(address) external view override returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }

    function flashFee(
        address token,
        uint256 amount
    ) public view override returns (uint256) {
        require(token == address(underlyingToken), "Unsupported currency");

        return (amount * flashLoanFee) / 10000;
    }

    function _getEstimatedAmountOut(
        address token,
        uint256 amountIn
    ) internal view returns (uint256 estimatedAmountOut) {
        address pool = uniswapFactory.getPool(
            token,
            address(underlyingToken),
            3000
        );
        require(pool != address(0), "Pool not found");

        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) /
            (2 ** 192);
        estimatedAmountOut = (amountIn * (price)) / (1e18); 
    }

    function _getOraclePrice(address token) internal view returns (uint256) {
        AggregatorV3Interface priceOracle = priceFeeds[token];
        require(
            address(priceOracle) != address(0),
            "Oracle not available for this token"
        );

        (, int256 price, , , ) = priceOracle.latestRoundData();
        require(price > 0, "Invalid price from oracle");

        // Chainlink oracles may have different decimals, so we need to normalize them to 18 decimals.
        uint8 decimals = priceOracle.decimals();
        return uint256(price) * (10 ** (18 - decimals));
    }
}