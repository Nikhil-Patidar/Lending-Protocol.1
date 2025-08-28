// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title Lending Protocol
 * @dev Decentralized lending and borrowing platform with collateral management
 * Features: Asset deposits, collateralized borrowing, interest accrual, and liquidation
 */
contract LendingProtocol is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Struct definitions
    struct Market {
        IERC20 token;
        uint256 totalDeposited;
        uint256 totalBorrowed;
        uint256 collateralFactor; // Percentage in basis points (e.g., 7500 = 75%)
        uint256 borrowRate; // Annual borrow rate in basis points
        uint256 supplyRate; // Annual supply rate in basis points
        uint256 lastUpdateTimestamp;
        bool isActive;
    }

    struct UserAccount {
        uint256 deposited;
        uint256 borrowed;
        uint256 lastInterestUpdate;
    }

    // State variables
    mapping(address => Market) public markets;
    mapping(address => mapping(address => UserAccount)) public userAccounts; // user => token => account
    mapping(address => uint256) public userTotalCollateralValue;
    mapping(address => uint256) public userTotalBorrowValue;
    
    address[] public supportedTokens;
    
    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80% - when position can be liquidated
    uint256 public constant LIQUIDATION_BONUS = 500; // 5% bonus for liquidators
    uint256 public constant MIN_HEALTH_FACTOR = 10000; // 100% minimum health factor

    // Events
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidation(address indexed liquidator, address indexed borrower, address indexed token, uint256 amount);
    event MarketAdded(address indexed token, uint256 collateralFactor, uint256 borrowRate);
    event InterestAccrued(address indexed token, uint256 borrowRate, uint256 supplyRate);

    constructor() Ownable(msg.sender) {}

    /**
     * @dev Core Function 1: Deposit tokens to earn interest and use as collateral
     * @param token Address of the token to deposit
     * @param amount Amount of tokens to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant {
        require(markets[token].isActive, "Market not active");
        require(amount > 0, "Amount must be greater than 0");
        
        Market storage market = markets[token];
        UserAccount storage account = userAccounts[msg.sender][token];
        
        // Accrue interest before deposit
        _accrueInterest(token);
        
        // Transfer tokens from user
        market.token.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user account
        account.deposited = account.deposited.add(amount);
        account.lastInterestUpdate = block.timestamp;
        
        // Update market totals
        market.totalDeposited = market.totalDeposited.add(amount);
        
        // Update user's total collateral value
        uint256 tokenValue = _getTokenValue(token, amount);
        userTotalCollateralValue[msg.sender] = userTotalCollateralValue[msg.sender].add(tokenValue);
        
        emit Deposit(msg.sender, token, amount);
    }

    /**
     * @dev Core Function 2: Borrow tokens against deposited collateral
     * @param token Address of the token to borrow
     * @param amount Amount of tokens to borrow
     */
    function borrow(address token, uint256 amount) external nonReentrant {
        require(markets[token].isActive, "Market not active");
        require(amount > 0, "Amount must be greater than 0");
        
        Market storage market = markets[token];
        UserAccount storage account = userAccounts[msg.sender][token];
        
        // Accrue interest before borrow
        _accrueInterest(token);
        
        // Check if user has enough collateral
        uint256 borrowValue = _getTokenValue(token, amount);
        uint256 maxBorrowValue = _getMaxBorrowValue(msg.sender);
        
        require(
            userTotalBorrowValue[msg.sender].add(borrowValue) <= maxBorrowValue,
            "Insufficient collateral"
        );
        
        // Check if market has enough liquidity
        uint256 availableLiquidity = market.totalDeposited.sub(market.totalBorrowed);
        require(amount <= availableLiquidity, "Insufficient liquidity");
        
        // Update user account
        account.borrowed = account.borrowed.add(amount);
        account.lastInterestUpdate = block.timestamp;
        
        // Update market totals
        market.totalBorrowed = market.totalBorrowed.add(amount);
        
        // Update user's total borrow value
        userTotalBorrowValue[msg.sender] = userTotalBorrowValue[msg.sender].add(borrowValue);
        
        // Transfer tokens to user
        market.token.safeTransfer(msg.sender, amount);
        
        emit Borrow(msg.sender, token, amount);
    }

    /**
     * @dev Core Function 3: Repay borrowed tokens with accrued interest
     * @param token Address of the token to repay
     * @param amount Amount of tokens to repay (0 means repay all)
     */
    function repay(address token, uint256 amount) external nonReentrant {
        require(markets[token].isActive, "Market not active");
        
        Market storage market = markets[token];
        UserAccount storage account = userAccounts[msg.sender][token];
        
        require(account.borrowed > 0, "No borrowed amount to repay");
        
        // Accrue interest before repay
        _accrueInterest(token);
        
        // Calculate accrued interest
        uint256 accruedInterest = _calculateAccruedInterest(token, msg.sender);
        uint256 totalOwed = account.borrowed.add(accruedInterest);
        
        // If amount is 0 or greater than owed, repay all
        if (amount == 0 || amount > totalOwed) {
            amount = totalOwed;
        }
        
        // Transfer repayment from user
        market.token.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user account
        uint256 principalRepaid = amount > accruedInterest ? amount.sub(accruedInterest) : 0;
        account.borrowed = account.borrowed.sub(principalRepaid);
        account.lastInterestUpdate = block.timestamp;
        
        // Update market totals
        market.totalBorrowed = market.totalBorrowed.sub(principalRepaid);
        
        // Update user's total borrow value
        uint256 repayValue = _getTokenValue(token, principalRepaid);
        userTotalBorrowValue[msg.sender] = userTotalBorrowValue[msg.sender].sub(repayValue);
        
        emit Repay(msg.sender, token, amount);
    }

    /**
     * @dev Withdraw deposited tokens (only if not needed for collateral)
     * @param token Address of the token to withdraw
     * @param amount Amount of tokens to withdraw
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        require(markets[token].isActive, "Market not active");
        require(amount > 0, "Amount must be greater than 0");
        
        Market storage market = markets[token];
        UserAccount storage account = userAccounts[msg.sender][token];
        
        require(account.deposited >= amount, "Insufficient deposit balance");
        
        // Accrue interest before withdrawal
        _accrueInterest(token);
        
        // Check if withdrawal maintains healthy collateralization
        uint256 withdrawValue = _getTokenValue(token, amount);
        uint256 newCollateralValue = userTotalCollateralValue[msg.sender].sub(withdrawValue);
        uint256 maxBorrowValue = newCollateralValue.mul(LIQUIDATION_THRESHOLD).div(BASIS_POINTS);
        
        require(
            userTotalBorrowValue[msg.sender] <= maxBorrowValue,
            "Withdrawal would make position unhealthy"
        );
        
        // Update user account
        account.deposited = account.deposited.sub(amount);
        
        // Update market totals
        market.totalDeposited = market.totalDeposited.sub(amount);
        
        // Update user's total collateral value
        userTotalCollateralValue[msg.sender] = userTotalCollateralValue[msg.sender].sub(withdrawValue);
        
        // Transfer tokens to user
        market.token.safeTransfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, token, amount);
    }

    /**
     * @dev Liquidate undercollateralized positions
     * @param borrower Address of the borrower to liquidate
     * @param tokenBorrowed Address of the borrowed token to repay
     * @param tokenCollateral Address of the collateral token to seize
     * @param repayAmount Amount of borrowed token to repay
     */
    function liquidate(
        address borrower,
        address tokenBorrowed,
        address tokenCollateral,
        uint256 repayAmount
    ) external nonReentrant {
        require(borrower != msg.sender, "Cannot liquidate self");
        require(_isLiquidatable(borrower), "Position is healthy");
        
        UserAccount storage borrowAccount = userAccounts[borrower][tokenBorrowed];
        UserAccount storage collateralAccount = userAccounts[borrower][tokenCollateral];
        
        require(borrowAccount.borrowed >= repayAmount, "Repay amount too high");
        require(collateralAccount.deposited > 0, "No collateral to seize");
        
        // Calculate collateral to seize (with liquidation bonus)
        uint256 collateralValue = _getTokenValue(tokenBorrowed, repayAmount);
        uint256 bonusValue = collateralValue.mul(LIQUIDATION_BONUS).div(BASIS_POINTS);
        uint256 totalSeizeValue = collateralValue.add(bonusValue);
        uint256 seizeAmount = _getTokenAmount(tokenCollateral, totalSeizeValue);
        
        // Ensure we don't seize more than available
        if (seizeAmount > collateralAccount.deposited) {
            seizeAmount = collateralAccount.deposited;
        }
        
        // Transfer repayment from liquidator
        markets[tokenBorrowed].token.safeTransferFrom(msg.sender, address(this), repayAmount);
        
        // Update borrower's accounts
        borrowAccount.borrowed = borrowAccount.borrowed.sub(repayAmount);
        collateralAccount.deposited = collateralAccount.deposited.sub(seizeAmount);
        
        // Update market totals
        markets[tokenBorrowed].totalBorrowed = markets[tokenBorrowed].totalBorrowed.sub(repayAmount);
        markets[tokenCollateral].totalDeposited = markets[tokenCollateral].totalDeposited.sub(seizeAmount);
        
        // Update borrower's total values
        userTotalBorrowValue[borrower] = userTotalBorrowValue[borrower].sub(_getTokenValue(tokenBorrowed, repayAmount));
        userTotalCollateralValue[borrower] = userTotalCollateralValue[borrower].sub(_getTokenValue(tokenCollateral, seizeAmount));
        
        // Transfer seized collateral to liquidator
        markets[tokenCollateral].token.safeTransfer(msg.sender, seizeAmount);
        
        emit Liquidation(msg.sender, borrower, tokenBorrowed, repayAmount);
    }

    /**
     * @dev Add a new token market (only owner)
     * @param token Address of the token
     * @param collateralFactor Collateral factor in basis points
     * @param borrowRate Initial borrow rate in basis points
     */
    function addMarket(
        address token,
        uint256 collateralFactor,
        uint256 borrowRate
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(!markets[token].isActive, "Market already exists");
        require(collateralFactor <= BASIS_POINTS, "Invalid collateral factor");
        
        markets[token] = Market({
            token: IERC20(token),
            totalDeposited: 0,
            totalBorrowed: 0,
            collateralFactor: collateralFactor,
            borrowRate: borrowRate,
            supplyRate: borrowRate.mul(8000).div(BASIS_POINTS), // 80% of borrow rate
            lastUpdateTimestamp: block.timestamp,
            isActive: true
        });
        
        supportedTokens.push(token);
        
        emit MarketAdded(token, collateralFactor, borrowRate);
    }

    /**
     * @dev Update interest rates for a market
     * @param token Address of the token market
     */
    function updateInterestRates(address token) external {
        _accrueInterest(token);
    }

    /**
     * @dev Get user's health factor (100% = 1e4)
     * @param user Address of the user
     */
    function getHealthFactor(address user) external view returns (uint256) {
        if (userTotalBorrowValue[user] == 0) return type(uint256).max;
        
        uint256 collateralValue = userTotalCollateralValue[user].mul(LIQUIDATION_THRESHOLD).div(BASIS_POINTS);
        return collateralValue.mul(BASIS_POINTS).div(userTotalBorrowValue[user]);
    }

    /**
     * @dev Get market information
     * @param token Address of the token market
     */
    function getMarketInfo(address token) external view returns (Market memory) {
        return markets[token];
    }

    /**
     * @dev Get user account information
     * @param user Address of the user
     * @param token Address of the token market
     */
    function getUserAccount(address user, address token) external view returns (UserAccount memory) {
        return userAccounts[user][token];
    }

    // Internal functions
    function _accrueInterest(address token) internal {
        Market storage market = markets[token];
        uint256 timeDelta = block.timestamp.sub(market.lastUpdateTimestamp);
        
        if (timeDelta > 0 && market.totalBorrowed > 0) {
            uint256 interestAccrued = market.totalBorrowed
                .mul(market.borrowRate)
                .mul(timeDelta)
                .div(SECONDS_PER_YEAR)
                .div(BASIS_POINTS);
            
            market.totalBorrowed = market.totalBorrowed.add(interestAccrued);
            market.lastUpdateTimestamp = block.timestamp;
            
            emit InterestAccrued(token, market.borrowRate, market.supplyRate);
        }
    }

    function _calculateAccruedInterest(address token, address user) internal view returns (uint256) {
        UserAccount memory account = userAccounts[user][token];
        Market memory market = markets[token];
        
        if (account.borrowed == 0) return 0;
        
        uint256 timeDelta = block.timestamp.sub(account.lastInterestUpdate);
        return account.borrowed
            .mul(market.borrowRate)
            .mul(timeDelta)
            .div(SECONDS_PER_YEAR)
            .div(BASIS_POINTS);
    }

    function _getMaxBorrowValue(address user) internal view returns (uint256) {
        return userTotalCollateralValue[user].mul(LIQUIDATION_THRESHOLD).div(BASIS_POINTS);
    }

    function _isLiquidatable(address user) internal view returns (bool) {
        if (userTotalBorrowValue[user] == 0) return false;
        
        uint256 healthFactor = userTotalCollateralValue[user]
            .mul(LIQUIDATION_THRESHOLD)
            .mul(BASIS_POINTS)
            .div(userTotalBorrowValue[user])
            .div(BASIS_POINTS);
        
        return healthFactor < MIN_HEALTH_FACTOR;
    }

    function _getTokenValue(address /*token*/, uint256 amount) internal pure returns (uint256) {
        // In a real implementation, this would use a price oracle
        // For simplicity, assuming 1:1 USD value for all tokens
        return amount;
    }

    function _getTokenAmount(address /*token*/, uint256 value) internal pure returns (uint256) {
        // In a real implementation, this would use a price oracle
        // For simplicity, assuming 1:1 USD value for all tokens
        return value;
    }

    /**
     * @dev Get list of supported tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /**
     * @dev Emergency pause function (only owner)
     * @param token Address of the token market to pause
     */
    function pauseMarket(address token) external onlyOwner {
        markets[token].isActive = false;
    }

    /**
     * @dev Unpause market function (only owner)
     * @param token Address of the token market to unpause
     */
    function unpauseMarket(address token) external onlyOwner {
        markets[token].isActive = true;
    }
}
