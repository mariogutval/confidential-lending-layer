// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
/**
 * ====================================================================
 *          Confidential Lending Core (fhEVM 0.6) — no float version
 * --------------------------------------------------------------------
 * Refactored to **remove the float buffer**. Every borrow pulls liquidity
 * directly from the external pool; every excess repayment is **refunded** to
 * the user in the callback. The vault never keeps user cash it doesn't need.
 * --------------------------------------------------------------------*/

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { TFHE, euint256, einput, ebool } from "fhevm/lib/TFHE.sol";
import { Gateway } from "fhevm/gateway/lib/Gateway.sol";
import { GatewayCaller } from "fhevm/gateway/GatewayCaller.sol";
import { SepoliaZamaFHEVMConfig } from "fhevm/config/ZamaFHEVMConfig.sol";
import { SepoliaZamaGatewayConfig } from "fhevm/config/ZamaGatewayConfig.sol";

/**
 * @title ConfidentialLendingCore
 * @notice A confidential lending protocol built on top of Compound V2 that uses FHE to encrypt user balances
 * @dev This contract implements a lending protocol where:
 *      1. Users deposit WETH as collateral
 *      2. Users can borrow USDC against their collateral
 *      3. All user balances are encrypted using FHE
 *      4. Health checks are performed on encrypted values
 *      5. The protocol uses Compound V2's cTokens for yield generation
 */

/* ─── Compound V2 minimal interface ─────────────────────────────── */
/**
 * @notice Minimal interface for Compound V2's cToken contracts
 * @dev The exchangeRateStored() function returns the exchange rate with underlyingDecimals + 10 decimals
 *      For example, for WETH (18 decimals), exchangeRateStored() returns a value with 28 decimals
 */
interface ICErc20 is IERC20 {
    function mint(uint256) external returns (uint256);
    function redeem(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function repayBorrow(uint256) external returns (uint256);
    function exchangeRateStored() external view returns (uint256); // underlyingDecimals + 10
}

contract ConfidentialLendingCore is SepoliaZamaFHEVMConfig, SepoliaZamaGatewayConfig, GatewayCaller, Pausable, Ownable {
    using SafeERC20 for IERC20;

    /* ─────────────────────────── ERRORS ─────────────────────────── */
    error ZeroAmount();
    error VaultHealthFactorLow();
    error MintFailed();
    error RedeemFailed();
    error BorrowFailed();
    error RepayFailed();
    error InvalidDecryption();
    error InvalidProof();

    /* ─────────────────────────── CONSTANTS ────────────────────────── */
    /// @notice Basis points for percentage calculations (100%)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Maximum loan-to-value ratio (80%)
    uint256 public constant MAX_VAULT_LTV = 8_000;

    /// @notice Minimum health factor in basis points (115%)
    uint256 public constant MIN_USER_HF_BP = 11_500;

    /// @notice Price of WETH in USDC (6 decimals)
    uint256 public constant WETH_PRICE_USDC = 3_000_000_000; // 3,000 USDC per WETH

    /// @notice Price of USDC in USDC (6 decimals)
    uint256 public constant USDC_PRICE_USDC = 1_000_000; // 1 USDC per USDC

    /// @notice Decimal places for WETH (18 decimals)
    uint256 public constant WETH_DECIMALS = 18;

    /// @notice Decimal places for USDC (6 decimals)
    uint256 public constant USDC_DECIMALS = 6;

    /// @notice Decimal places for cTokens (Compound V2 standard)
    uint256 public constant CTOKEN_DECIMALS = 8;

    /// @notice Decimal places for exchange rate (underlyingDecimals + 10)
    uint256 public constant EXCHANGE_RATE_DECIMALS = 28; // WETH_DECIMALS + 10

    /// @notice Timeout for borrow decryption (60 seconds)
    uint256 public constant BORROW_TIMEOUT = 60;

    /// @notice Timeout for withdraw/repay decryption (120 seconds)
    uint256 public constant WITHDRAW_REPAY_TIMEOUT = 120;

    /* ───────────────────────────── TOKENS ─────────────────────────── */
    /// @notice The underlying WETH token used as collateral
    IERC20 public immutable collateralToken;

    /// @notice The underlying USDC token used as debt
    IERC20 public immutable debtToken;

    /// @notice The cWETH token from Compound V2
    ICErc20 public immutable collateralCToken;

    /// @notice The cUSDC token from Compound V2
    ICErc20 public immutable debtCToken;

    /* ───────────────────────────── STORAGE ────────────────────────── */
    /// @notice Encrypted cToken balance for each user
    /// @dev Stored in cToken decimals (8)
    mapping(address => euint256) private _encryptedCollateralCToken;

    /// @notice Encrypted debt balance for each user
    /// @dev Stored in USDC decimals (6)
    mapping(address => euint256) private _encryptedDebtUnderlying;

    /// @notice Total cTokens deposited in the protocol
    /// @dev Stored in cToken decimals (8)
    uint256 public totalCollateralCTokens;

    /// @notice Total debt in the protocol
    /// @dev Stored in USDC decimals (6)
    uint256 public totalDebtUnderlying;

    /// @notice Structure for pending borrow requests
    struct PendingBorrow {
        address user;
        euint256 amountEnc; // Encrypted amount in USDC decimals (6)
    }

    /// @notice Structure for pending withdraw requests
    struct PendingWithdraw {
        address user;
        euint256 amount; // Encrypted amount in cToken decimals (8)
    }

    /// @notice Mapping of request IDs to pending borrows
    mapping(uint256 => PendingBorrow) private _pendingBorrow;

    /// @notice Mapping of request IDs to pending withdraws
    mapping(uint256 => PendingWithdraw) private _pendingWithdraw;

    /// @notice Mapping of request IDs to pending repays
    mapping(uint256 => address) private _pendingRepay;

    /* ───────────────────────────── EVENTS ─────────────────────────── */
    event CollateralDeposited(address indexed user, uint256 amount);
    event BorrowQueued(address indexed user, uint256 reqId);
    event Borrowed(address indexed user, uint256 amount);
    event RepayQueued(address indexed user, uint256 reqId);
    event Repaid(address indexed user, uint256 amount);
    event WithdrawQueued(address indexed user, uint256 id);
    event Withdrawn(address indexed user, uint256 usdcAmount);
    event Paused();
    event Unpaused();

    /**
     * @notice Initializes the contract with token addresses
     * @param _collateralToken Address of the WETH token
     * @param _debtToken Address of the USDC token
     * @param _collateralCToken Address of the cWETH token
     * @param _debtCToken Address of the cUSDC token
     */
    constructor(
        address _collateralToken,
        address _debtToken,
        address _collateralCToken,
        address _debtCToken
    ) Ownable(msg.sender) {
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        collateralCToken = ICErc20(_collateralCToken);
        debtCToken = ICErc20(_debtCToken);

        // Approve cTokens to spend underlying tokens
        collateralToken.safeIncreaseAllowance(address(collateralCToken), type(uint256).max);
        debtToken.safeIncreaseAllowance(address(debtCToken), type(uint256).max);
    }

    /* ─────────────────────────── HELPERS ──────────────────────────── */
    /**
     * @notice Checks if the vault's health factor is above the minimum threshold
     * @dev Converts all values to USDC (6 decimals) for comparison
     * @param newCollateralCTokens New total cTokens in the vault (8 decimals)
     * @param newDebt New total debt in the vault (6 decimals)
     */
    function _requireVaultHealthy(uint256 newCollateralCTokens, uint256 newDebt) internal view {
        // Convert cToken to underlying (WETH) using exchangeRate
        // cToken (8 decimals) * exchangeRate (28 decimals) / 1e8 = WETH (18 decimals)
        uint256 collateralInWeth = (newCollateralCTokens * collateralCToken.exchangeRateStored()) / 1e8;

        // Convert WETH to USDC
        // WETH (18 decimals) * WETH_PRICE_USDC (6 decimals) / 1e18 = USDC (6 decimals)
        uint256 collateralInUsdc = (collateralInWeth * WETH_PRICE_USDC) / 1e18;

        // Calculate max borrow in USDC
        // collateralInUsdc (6 decimals) * MAX_VAULT_LTV / BASIS_POINTS = USDC (6 decimals)
        uint256 maxBorrowUSDC = (collateralInUsdc * MAX_VAULT_LTV) / BASIS_POINTS;

        // Convert debt to USDC (both already in 6 decimals)
        uint256 totalDebtUSDC = newDebt * USDC_PRICE_USDC;

        if (maxBorrowUSDC < totalDebtUSDC) revert VaultHealthFactorLow();
    }

    /**
     * @notice Checks if a user's health factor is above the minimum threshold
     * @dev Performs FHE operations to compare encrypted values
     * @param encryptedCollateralUnderlying User's encrypted WETH balance (18 decimals)
     * @param encryptedDebtUnderlying User's encrypted USDC debt (6 decimals)
     * @return isHealthy True if the user's health factor is above the minimum
     */
    function _requireUserHealthy(
        euint256 encryptedCollateralUnderlying,
        euint256 encryptedDebtUnderlying
    ) internal returns (ebool isHealthy) {
        // Convert collateral to USDC (6 decimals)
        // WETH (18 decimals) * USDC price (6 decimals) / 1e18 = USDC (6 decimals)
        euint256 collateralInUsdc = TFHE.div(TFHE.mul(encryptedCollateralUnderlying, WETH_PRICE_USDC), 1e18);
        TFHE.allow(collateralInUsdc, address(this));

        // Calculate max allowed debt in USDC (6 decimals)
        // collateralInUsdc (6 decimals) * MAX_VAULT_LTV / BASIS_POINTS = USDC (6 decimals)
        euint256 maxAllowedDebt = TFHE.div(TFHE.mul(collateralInUsdc, MAX_VAULT_LTV), BASIS_POINTS);
        TFHE.allow(maxAllowedDebt, address(this));

        // Compare max allowed debt with actual debt (both in USDC)
        isHealthy = TFHE.ge(maxAllowedDebt, encryptedDebtUnderlying);
        TFHE.allow(isHealthy, address(this));
    }

    /**
     * @notice Safely gets an encrypted value, returning 0 if not initialized
     * @dev This prevents FHE operations on uninitialized values
     * @param s The encrypted value to check
     * @return The encrypted value or 0 if not initialized
     */
    function _safeSlot(euint256 s) internal returns (euint256) {
        if (TFHE.isInitialized(s)) return s;
        euint256 zero = TFHE.asEuint256(0);
        TFHE.allow(zero, address(this));
        return zero;
    }

    /**
     * @notice Converts a user's encrypted cToken balance to underlying WETH
     * @dev Uses Compound V2's exchange rate to convert cToken to WETH
     * @param user The user's address
     * @return The encrypted WETH balance (18 decimals)
     */
    function _encryptedCollateralUnderlying(address user) internal returns (euint256) {
        // Cache the exchange rate to avoid multiple calls
        uint256 rate = collateralCToken.exchangeRateStored(); // 28 decimals (WETH_DECIMALS + 10)

        // Get current collateral and convert to underlying in one operation
        euint256 currentCollateral = _safeSlot(_encryptedCollateralCToken[user]);

        // Convert cToken to underlying (WETH)
        // cToken (8 decimals) * exchangeRate (28 decimals) / 1e8 = WETH (18 decimals)
        euint256 result = TFHE.div(TFHE.mul(currentCollateral, rate), 1e8);
        TFHE.allow(result, address(this));
        return result;
    }

    /**
     * @notice Updates a user's encrypted cToken balance
     * @dev Handles both deposits and withdrawals
     * @param user The user's address
     * @param amount The amount to add or subtract (8 decimals)
     * @param isAdd True to add, false to subtract
     */
    function _updateEncryptedCollateral(address user, euint256 amount, bool isAdd) internal {
        euint256 currentAmount = _safeSlot(_encryptedCollateralCToken[user]);
        _encryptedCollateralCToken[user] = isAdd ? TFHE.add(currentAmount, amount) : TFHE.sub(currentAmount, amount);

        TFHE.allow(_encryptedCollateralCToken[user], address(this));
        TFHE.allow(_encryptedCollateralCToken[user], user);
    }

    /**
     * @notice Updates a user's encrypted debt balance
     * @dev Handles both borrows and repays
     * @param user The user's address
     * @param amount The amount to add or subtract (6 decimals)
     * @param isAdd True to add, false to subtract
     */
    function _updateEncryptedDebt(address user, euint256 amount, bool isAdd) internal {
        euint256 currentAmount = _safeSlot(_encryptedDebtUnderlying[user]);
        _encryptedDebtUnderlying[user] = isAdd ? TFHE.add(currentAmount, amount) : TFHE.sub(currentAmount, amount);

        TFHE.allow(_encryptedDebtUnderlying[user], address(this));
        TFHE.allow(_encryptedDebtUnderlying[user], user);
    }

    /**
     * @notice Requests decryption of an encrypted value
     * @dev Handles the common decryption request pattern
     * @param encryptedValue The encrypted value to decrypt
     * @param callbackSelector The selector of the callback function
     * @param timeout The timeout in seconds
     * @return id The decryption request ID
     */
    function _requestDecryption(
        euint256 encryptedValue,
        bytes4 callbackSelector,
        uint256 timeout
    ) internal returns (uint256 id) {
        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(encryptedValue);
        id = Gateway.requestDecryption(cts, callbackSelector, 0, block.timestamp + timeout, false);
    }

    /* ────────────────────────── USER ACTIONS ───────────────────────── */
    /**
     * @notice Deposits WETH as collateral
     * @dev Converts WETH to cWETH and updates encrypted balances
     * @param underlyingAmount Amount of WETH to deposit (18 decimals)
     */
    function depositCollateral(uint256 underlyingAmount) external whenNotPaused {
        if (underlyingAmount == 0) revert ZeroAmount();

        // Transfer WETH from user
        collateralToken.safeTransferFrom(msg.sender, address(this), underlyingAmount);

        // Mint cWETH
        uint256 cTokenBalanceBefore = collateralCToken.balanceOf(address(this));
        if (collateralCToken.mint(underlyingAmount) != 0) revert MintFailed();
        uint256 cTokenBalanceAfter = collateralCToken.balanceOf(address(this));
        uint256 cTokenMinted = cTokenBalanceAfter - cTokenBalanceBefore;

        // Update encrypted balances
        _updateEncryptedCollateral(msg.sender, TFHE.asEuint256(cTokenMinted), true);
        totalCollateralCTokens += cTokenMinted;

        emit CollateralDeposited(msg.sender, underlyingAmount);
    }

    /**
     * @notice Initiates a withdrawal of WETH collateral
     * @dev Checks health factor on encrypted values before allowing withdrawal
     * @param encryptedCTokenAmount Encrypted amount of cWETH to withdraw (8 decimals)
     * @param inputProof Zero-knowledge proof of the encrypted amount
     */
    function withdraw(einput encryptedCTokenAmount, bytes calldata inputProof) external whenNotPaused {
        euint256 cTokenAmountEnc = TFHE.asEuint256(encryptedCTokenAmount, inputProof);
        TFHE.allow(cTokenAmountEnc, address(this));

        // Get current encrypted balances
        euint256 encryptedCollateralUnderlying = _encryptedCollateralUnderlying(msg.sender);
        euint256 encryptedDebtUnderlying = _safeSlot(_encryptedDebtUnderlying[msg.sender]);

        // Check health factor
        ebool isUserHealthy = _requireUserHealthy(encryptedCollateralUnderlying, encryptedDebtUnderlying);
        euint256 queued = TFHE.select(isUserHealthy, cTokenAmountEnc, TFHE.asEuint256(uint256(0)));
        TFHE.allow(queued, address(this));

        // Request decryption
        uint256 id = _requestDecryption(queued, this.withdrawCallback.selector, WITHDRAW_REPAY_TIMEOUT);
        _pendingWithdraw[id] = PendingWithdraw(msg.sender, queued);

        emit WithdrawQueued(msg.sender, id);
    }

    /**
     * @notice Callback for withdrawal decryption
     * @dev Converts cWETH back to WETH and transfers to user
     * @param id The decryption request ID
     * @param withdrawAmount The decrypted amount of cWETH to withdraw (8 decimals)
     */
    function withdrawCallback(uint256 id, uint256 withdrawAmount) external onlyGateway {
        PendingWithdraw memory pendingWithdraw = _pendingWithdraw[id];
        delete _pendingWithdraw[id];

        if (withdrawAmount == 0) return;

        // Check vault health with new balances
        uint256 newCollateralCTokens = totalCollateralCTokens - withdrawAmount;
        _requireVaultHealthy(newCollateralCTokens, totalDebtUnderlying);

        // Update encrypted balances
        _updateEncryptedCollateral(pendingWithdraw.user, TFHE.asEuint256(withdrawAmount), false);
        totalCollateralCTokens = newCollateralCTokens;

        // Redeem cWETH for WETH
        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(this));
        if (collateralCToken.redeem(withdrawAmount) != 0) revert RedeemFailed();
        uint256 collateralBalanceAfter = collateralToken.balanceOf(address(this));

        // Transfer WETH to user
        uint256 underlyingAmount = collateralBalanceAfter - collateralBalanceBefore;
        collateralToken.safeTransfer(pendingWithdraw.user, underlyingAmount);

        emit Withdrawn(pendingWithdraw.user, underlyingAmount);
    }

    /**
     * @notice Initiates a borrow of USDC
     * @dev Checks health factor on encrypted values before allowing borrow
     * @param encryptedUnderlyingAmount Encrypted amount of USDC to borrow (6 decimals)
     * @param proofUnderlyingAmount Zero-knowledge proof of the encrypted amount
     */
    function borrow(einput encryptedUnderlyingAmount, bytes calldata proofUnderlyingAmount) external whenNotPaused {
        euint256 underlyingAmountEnc = TFHE.asEuint256(encryptedUnderlyingAmount, proofUnderlyingAmount);
        TFHE.allow(underlyingAmountEnc, address(this));

        // Get current encrypted balances
        euint256 encryptedCollateralUnderlying = _encryptedCollateralUnderlying(msg.sender);
        euint256 encryptedDebtUnderlying = _safeSlot(_encryptedDebtUnderlying[msg.sender]);

        // Check health factor
        ebool isUserHealthy = _requireUserHealthy(encryptedCollateralUnderlying, encryptedDebtUnderlying);
        euint256 queued = TFHE.select(isUserHealthy, underlyingAmountEnc, TFHE.asEuint256(uint256(0)));
        TFHE.allow(queued, address(this));

        // Request decryption
        uint256 id = _requestDecryption(queued, this.borrowCallback.selector, BORROW_TIMEOUT);
        _pendingBorrow[id] = PendingBorrow(msg.sender, queued);

        emit BorrowQueued(msg.sender, id);
    }

    /**
     * @notice Callback for borrow decryption
     * @dev Borrows USDC from Compound and transfers to user
     * @param id The decryption request ID
     * @param borrowAmount The decrypted amount of USDC to borrow (6 decimals)
     */
    function borrowCallback(uint256 id, uint256 borrowAmount) external onlyGateway {
        PendingBorrow memory pendingBorrow = _pendingBorrow[id];
        delete _pendingBorrow[id];

        if (borrowAmount == 0) return;

        // Check vault health with new balances
        uint256 newDebt = totalDebtUnderlying + borrowAmount;
        _requireVaultHealthy(totalCollateralCTokens, newDebt);

        // Update encrypted balances
        _updateEncryptedDebt(pendingBorrow.user, TFHE.asEuint256(borrowAmount), true);
        totalDebtUnderlying = newDebt;

        // Borrow USDC from Compound
        uint256 success = debtCToken.borrow(borrowAmount);
        if (success != 0) revert BorrowFailed();
        debtToken.safeTransfer(pendingBorrow.user, borrowAmount);

        emit Borrowed(pendingBorrow.user, borrowAmount);
    }

    /**
     * @notice Initiates a repayment of USDC debt
     * @dev Handles over-repayment by only taking the necessary amount
     * @param repayAmount Amount of USDC to repay (6 decimals)
     * @param encryptedRepayAmount Encrypted amount of USDC to repay (6 decimals)
     * @param proofRepayAmount Zero-knowledge proof of the encrypted amount
     */
    function repay(
        uint256 repayAmount,
        einput encryptedRepayAmount,
        bytes calldata proofRepayAmount
    ) external whenNotPaused {
        if (repayAmount == 0) revert ZeroAmount();

        euint256 repayAmountEnc = TFHE.asEuint256(encryptedRepayAmount, proofRepayAmount);
        TFHE.allow(repayAmountEnc, address(this));
        euint256 debtEnc = _safeSlot(_encryptedDebtUnderlying[msg.sender]);
        TFHE.allow(debtEnc, address(this));

        // Handle over-repayment
        ebool isOverRepayment = TFHE.lt(debtEnc, repayAmountEnc);
        euint256 result = TFHE.select(isOverRepayment, debtEnc, repayAmountEnc);
        TFHE.allow(result, address(this));

        // Request decryption
        uint256 id = _requestDecryption(result, this.repayCallback.selector, WITHDRAW_REPAY_TIMEOUT);
        _pendingRepay[id] = msg.sender;

        emit RepayQueued(msg.sender, id);
    }

    /**
     * @notice Callback for repay decryption
     * @dev Repays USDC debt to Compound
     * @param id The decryption request ID
     * @param repayAmount The decrypted amount of USDC to repay (6 decimals)
     */
    function repayCallback(uint256 id, uint256 repayAmount) external onlyGateway {
        address user = _pendingRepay[id];
        delete _pendingRepay[id];

        // Transfer USDC from user
        debtToken.safeTransferFrom(user, address(this), repayAmount);

        // Repay debt to Compound
        if (debtCToken.repayBorrow(repayAmount) != 0) revert RepayFailed();

        // Update encrypted balances
        _updateEncryptedDebt(user, TFHE.asEuint256(repayAmount), false);
        totalDebtUnderlying -= repayAmount;

        emit Repaid(user, repayAmount);
    }

    /* ─────────────── ADMIN & VIEWS ─────────────── */
    /**
     * @notice Pauses the contract
     * @dev Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
        emit Paused();
    }

    /**
     * @notice Unpauses the contract
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
        emit Unpaused();
    }

    /**
     * @notice Gets a user's encrypted debt balance
     * @param u The user's address
     * @return The encrypted debt balance (6 decimals)
     */
    function encryptedDebtOf(address u) external view returns (uint256) {
        return Gateway.toUint256(_encryptedDebtUnderlying[u]);
    }

    /**
     * @notice Gets a user's encrypted collateral balance
     * @param u The user's address
     * @return The encrypted collateral balance (8 decimals)
     */
    function encryptedCollOf(address u) external view returns (uint256) {
        return Gateway.toUint256(_encryptedCollateralCToken[u]);
    }
}
