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

/* ─── Compound V2 minimal interface ─────────────────────────────── */
interface ICErc20 is IERC20 {
    function mint(uint256) external returns (uint256);
    function redeem(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function repayBorrow(uint256) external returns (uint256);
    function exchangeRateStored() external view returns (uint256); // 18‑dec
}

contract ConfidentialLendingCore is SepoliaZamaFHEVMConfig, SepoliaZamaGatewayConfig, GatewayCaller, Pausable, Ownable {
    using SafeERC20 for IERC20;

    /* ─────────────────────────── ERRORS ─────────────────────────── */
    error ZeroAmount();
    error VaultHealthFactorLow();
    error MintFailed();
    error RedeemFailed();
    error BorrowFailed();

    /* ─────────────────────────── CONSTANTS ────────────────────────── */
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_VAULT_LTV = 8_000; // 80%
    uint256 public constant MIN_USER_HF_BP = 11_500; // 1.15×

    // Price constants (in USD, with 6 decimals)
    uint256 public constant WETH_PRICE_USD = 3_000_000_000; // $3,000 per WETH
    uint256 public constant USDC_PRICE_USD = 1_000_000; // $1 per USDC

    /* ───────────────────────────── TOKENS ─────────────────────────── */
    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    ICErc20 public immutable cToken;

    /* ───────────────────────────── STORAGE ────────────────────────── */
    mapping(address => euint256) private _encryptedCollateralCToken;
    mapping(address => euint256) private _encryptedDebtUnderlying;

    uint256 public totalCollateralCTokens;
    uint256 public totalDebtUnderlying;

    struct PendingBorrow {
        address user;
        euint256 amountEnc;
    }

    struct PendingWithdraw {
        address user;
        euint256 amount;
    }

    mapping(uint256 => PendingBorrow) private _pendingBorrow;
    mapping(uint256 => PendingWithdraw) private _pendingWithdraw;
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

    /* ──────────────────────────── INIT ────────────────────────────── */
    constructor(address _collateralToken, address _debtToken, address _cToken) Ownable(msg.sender) {
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        cToken = ICErc20(_cToken);

        collateralToken.safeIncreaseAllowance(address(cToken), type(uint256).max);
        debtToken.safeIncreaseAllowance(address(cToken), type(uint256).max);
    }

    /* ─────────────────────────── HELPERS ──────────────────────────── */
    function _requireVaultHealthy(uint256 newCollateralCTokens, uint256 newDebt) internal view {
        // Convert both amounts to USD (6 decimals)
        uint256 cTokenCollateralUsd = (newCollateralCTokens * cToken.exchangeRateStored() * WETH_PRICE_USD) / 1e18;
        uint256 debtUsd = (newDebt * USDC_PRICE_USD) / 1e6;

        uint256 maxBorrowUSD = cTokenCollateralUsd * MAX_VAULT_LTV;
        uint256 totalDebtUSD = debtUsd * BASIS_POINTS;

        if (maxBorrowUSD < totalDebtUSD) revert VaultHealthFactorLow();
    }

    function _requireUserHealthy(
        euint256 encryptedCollateralUnderlying,
        euint256 encryptedDebtUnderlying
    ) internal returns (ebool isHealthy) {
        euint256 collateralUsd = TFHE.div(
            TFHE.mul(encryptedCollateralUnderlying, TFHE.asEuint256(WETH_PRICE_USD)),
            1e18
        );
        euint256 debtUsd = TFHE.div(TFHE.mul(encryptedDebtUnderlying, TFHE.asEuint256(USDC_PRICE_USD)), 1e6);

        isHealthy = TFHE.ge(
            TFHE.mul(collateralUsd, TFHE.asEuint256(BASIS_POINTS)),
            TFHE.mul(debtUsd, TFHE.asEuint256(MIN_USER_HF_BP))
        );
    }

    function _safeSlot(euint256 s) internal returns (euint256) {
        if (TFHE.isInitialized(s)) return s;
        euint256 zero = TFHE.asEuint256(uint256(0));
        TFHE.allow(zero, address(this));
        return zero;
    }

    function _encryptedCollateralUnderlying(address user) internal returns (euint256) {
        uint256 rate = cToken.exchangeRateStored();
        return TFHE.div(TFHE.mul(_safeSlot(_encryptedCollateralCToken[user]), TFHE.asEuint256(rate)), 1e18);
    }

    function _updateEncryptedCollateral(address user, euint256 amount, bool isAdd) internal {
        euint256 currentAmount = _safeSlot(_encryptedCollateralCToken[user]);
        _encryptedCollateralCToken[user] = isAdd ? TFHE.add(currentAmount, amount) : TFHE.sub(currentAmount, amount);

        TFHE.allow(_encryptedCollateralCToken[user], user);
        TFHE.allow(_encryptedCollateralCToken[user], address(this));
    }

    function _updateEncryptedDebt(address user, euint256 amount, bool isAdd) internal {
        euint256 currentAmount = _safeSlot(_encryptedDebtUnderlying[user]);
        _encryptedDebtUnderlying[user] = isAdd ? TFHE.add(currentAmount, amount) : TFHE.sub(currentAmount, amount);

        TFHE.allow(_encryptedDebtUnderlying[user], user);
        TFHE.allow(_encryptedDebtUnderlying[user], address(this));
    }

    /* ────────────────────────── USER ACTIONS ───────────────────────── */
    function depositCollateral(uint256 underlyingAmount) external whenNotPaused {
        if (underlyingAmount == 0) revert ZeroAmount();

        collateralToken.safeTransferFrom(msg.sender, address(this), underlyingAmount);

        uint256 cTokenBalanceBefore = cToken.balanceOf(address(this));
        if (cToken.mint(underlyingAmount) != 0) revert MintFailed();
        uint256 cTokenBalanceAfter = cToken.balanceOf(address(this));
        uint256 cTokenMinted = cTokenBalanceAfter - cTokenBalanceBefore;

        _updateEncryptedCollateral(msg.sender, TFHE.asEuint256(cTokenMinted), true);
        totalCollateralCTokens += cTokenMinted;

        emit CollateralDeposited(msg.sender, underlyingAmount);
    }

    function withdraw(einput encryptedCTokenAmount, bytes calldata inputProof) external whenNotPaused {
        euint256 cTokenAmountEnc = TFHE.asEuint256(encryptedCTokenAmount, inputProof);
        TFHE.allow(cTokenAmountEnc, address(this));

        euint256 encryptedCollateralUnderlying = _encryptedCollateralUnderlying(msg.sender);
        euint256 encryptedDebtUnderlying = _safeSlot(_encryptedDebtUnderlying[msg.sender]);

        ebool isUserHealthy = _requireUserHealthy(encryptedCollateralUnderlying, encryptedDebtUnderlying);
        euint256 queued = TFHE.select(isUserHealthy, cTokenAmountEnc, TFHE.asEuint256(uint256(0)));
        TFHE.allow(queued, address(this));

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(queued);
        uint256 id = Gateway.requestDecryption(cts, this.withdrawCallback.selector, 0, block.timestamp + 120, false);
        _pendingWithdraw[id] = PendingWithdraw(msg.sender, queued);

        emit WithdrawQueued(msg.sender, id);
    }

    function withdrawCallback(uint256 id, uint256 withdrawAmount) external onlyGateway {
        PendingWithdraw memory pendingWithdraw = _pendingWithdraw[id];
        delete _pendingWithdraw[id];

        if (withdrawAmount == 0) return;

        uint256 newCollateralCTokens = totalCollateralCTokens - withdrawAmount;
        _requireVaultHealthy(newCollateralCTokens, totalDebtUnderlying);

        _updateEncryptedCollateral(pendingWithdraw.user, TFHE.asEuint256(withdrawAmount), false);
        totalCollateralCTokens = newCollateralCTokens;

        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(this));
        if (cToken.redeem(withdrawAmount) != 0) revert RedeemFailed();
        uint256 collateralBalanceAfter = collateralToken.balanceOf(address(this));

        uint256 underlyingAmount = collateralBalanceAfter - collateralBalanceBefore;
        collateralToken.safeTransfer(pendingWithdraw.user, underlyingAmount);

        emit Withdrawn(pendingWithdraw.user, underlyingAmount);
    }

    function borrow(einput encryptedUnderlyingAmount, bytes calldata proofUnderlyingAmount) external whenNotPaused {
        euint256 underlyingAmountEnc = TFHE.asEuint256(encryptedUnderlyingAmount, proofUnderlyingAmount);

        euint256 encryptedCollateralUnderlying = _encryptedCollateralUnderlying(msg.sender);
        euint256 encryptedDebtUnderlying = _safeSlot(_encryptedDebtUnderlying[msg.sender]);

        ebool isUserHealthy = _requireUserHealthy(encryptedCollateralUnderlying, encryptedDebtUnderlying);
        euint256 queued = TFHE.select(isUserHealthy, underlyingAmountEnc, TFHE.asEuint256(uint256(0)));
        TFHE.allow(queued, address(this));

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(queued);
        uint256 id = Gateway.requestDecryption(cts, this.borrowCallback.selector, 0, block.timestamp + 300, false);
        _pendingBorrow[id] = PendingBorrow(msg.sender, queued);

        emit BorrowQueued(msg.sender, id);
    }

    function borrowCallback(uint256 id, uint256 borrowAmount) external onlyGateway {
        PendingBorrow memory pendingBorrow = _pendingBorrow[id];
        delete _pendingBorrow[id];

        if (borrowAmount == 0) return;

        uint256 newDebt = totalDebtUnderlying + borrowAmount;
        _requireVaultHealthy(totalCollateralCTokens, newDebt);

        _updateEncryptedDebt(pendingBorrow.user, TFHE.asEuint256(borrowAmount), true);
        totalDebtUnderlying = newDebt;

        if (cToken.borrow(borrowAmount) != 0) revert BorrowFailed();
        debtToken.safeTransfer(pendingBorrow.user, borrowAmount);

        emit Borrowed(pendingBorrow.user, borrowAmount);
    }

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

        ebool isOverRepayment = TFHE.lt(debtEnc, repayAmountEnc);
        euint256 result = TFHE.select(isOverRepayment, debtEnc, repayAmountEnc);
        TFHE.allow(result, address(this));

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(result);
        uint256 id = Gateway.requestDecryption(cts, this.repayCallback.selector, 0, block.timestamp + 120, false);
        _pendingRepay[id] = msg.sender;

        emit RepayQueued(msg.sender, id);
    }

    function repayCallback(uint256 id, uint256 repayAmount) external onlyGateway {
        address user = _pendingRepay[id];
        delete _pendingRepay[id];

        debtToken.safeTransferFrom(user, address(this), repayAmount);
        cToken.repayBorrow(repayAmount);

        _updateEncryptedDebt(user, TFHE.asEuint256(repayAmount), false);
        totalDebtUnderlying -= repayAmount;

        emit Repaid(user, repayAmount);
    }

    /* ─────────────── ADMIN & VIEWS ─────────────── */
    function pause() external onlyOwner {
        _pause();
        emit Paused();
    }

    function unpause() external onlyOwner {
        _unpause();
        emit Unpaused();
    }

    function encryptedDebtOf(address u) external view returns (uint256) {
        return Gateway.toUint256(_encryptedDebtUnderlying[u]);
    }

    function encryptedCollOf(address u) external view returns (uint256) {
        return Gateway.toUint256(_encryptedCollateralCToken[u]);
    }
}
