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

interface IAaveLikePool {
    function supply(address asset, uint256 amt, address onBehalf, uint16 refCode) external;
    function withdraw(address asset, uint256 amt, address to) external returns (uint256);
}

contract ConfidentialLendingCore is
    SepoliaZamaFHEVMConfig,
    SepoliaZamaGatewayConfig,
    GatewayCaller,
    Pausable,
    Ownable
{
    using SafeERC20 for IERC20;

    /* ─────────────────────────── CONSTANTS ────────────────────────── */
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_VAULT_LTV = 8_000; // 80 %
    uint256 public constant MIN_USER_HF_BP = 11_500; // 1.15×

    // Price constants (in USD, with 6 decimals)
    uint256 public constant WETH_PRICE_USD = 3_000_000_000; // $3,000 per WETH
    uint256 public constant USDC_PRICE_USD = 1_000_000; // $1 per USDC

    /* ───────────────────────────── TOKENS ─────────────────────────── */
    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;
    IAaveLikePool public immutable pool;

    /* ───────────────────────────── STORAGE ────────────────────────── */
    mapping(address => euint256) private _eColl;
    mapping(address => euint256) private _eDebt;

    uint256 public totalCollateral;
    uint256 public totalDebt;

    struct PendingBorrow {
        address user;
        euint256 amountEnc;
    }
    mapping(uint256 => PendingBorrow) private _pendingBorrow;

    struct PendingRepay {
        address user;
        uint256 amount;
    }
    mapping(uint256 => address) private _pendingRepay;

    /* ───────────────────────────── EVENTS ─────────────────────────── */
    event CollateralDeposited(address indexed user, uint256 amount);
    event BorrowQueued(address indexed user, uint256 reqId);
    event Borrowed(address indexed user, uint256 amount);
    event RepayQueued(address indexed user, uint256 reqId);
    event Repaid(address indexed user, uint256 amount);
    event Paused();
    event Unpaused();

    /* ──────────────────────────── INIT ────────────────────────────── */
    constructor(address _coll, address _debt, address _pool) Ownable(msg.sender) {
        collateralToken = IERC20(_coll);
        debtToken = IERC20(_debt);
        pool = IAaveLikePool(_pool);
    }

    /* ─────────────────────────── HELPERS ──────────────────────────── */
    function _requireVaultHealthy(uint256 newDebt) internal view {
        // Convert both amounts to USD (6 decimals)
        // WETH collateral is in 18 decimals, so divide by 1e18 and multiply by WETH price
        // totalCollateral is in 18 decimals (WETH)
        // WETH_PRICE_USD is in 6 decimals
        // Result should be in 6 decimals
        uint256 collateralUsd = (totalCollateral * WETH_PRICE_USD) / 1e18;

        // USDC debt is in 6 decimals
        // USDC_PRICE_USD is in 6 decimals
        // Result should be in 6 decimals
        uint256 debtUsd = (newDebt * USDC_PRICE_USD) / 1e6;

        uint256 maxBorrowUSD = collateralUsd * MAX_VAULT_LTV;
        uint256 totalDebtUSD = debtUsd * BASIS_POINTS;

        require(maxBorrowUSD >= totalDebtUSD, "vault HF low");
    }

    function _safeSlot(euint256 s) internal returns (euint256) {
        if (TFHE.isInitialized(s)) return s; // slot already has ACL
        euint256 zero = TFHE.asEuint256(uint256(0)); // fresh zero-ciphertext
        TFHE.allow(zero, address(this)); // whitelist the vault once
        return zero;
    }

    /* ────────────────────────── USER ACTIONS ───────────────────────── */
    function depositCollateral(
        uint256 amt,
        einput encZeroDebt,
        bytes calldata proofZeroDebt
    ) external whenNotPaused {
        require(amt > 0, "amt 0");
        collateralToken.safeTransferFrom(msg.sender, address(this), amt);

        _eColl[msg.sender] = TFHE.add(_safeSlot(_eColl[msg.sender]), TFHE.asEuint256(amt));
        TFHE.allow(_eColl[msg.sender], msg.sender);
        TFHE.allow(_eColl[msg.sender], address(this));
        totalCollateral += amt;

        // decorrelate debt slot
        euint256 rnd = TFHE.asEuint256(encZeroDebt, proofZeroDebt);
        _eDebt[msg.sender] = TFHE.add(_safeSlot(_eDebt[msg.sender]), rnd);
        TFHE.allow(_eDebt[msg.sender], msg.sender);
        TFHE.allow(_eDebt[msg.sender], address(this));

        emit CollateralDeposited(msg.sender, amt);
    }

    function borrow(einput encAmt, bytes calldata proofAmt) external whenNotPaused {
        euint256 amtEnc = TFHE.asEuint256(encAmt, proofAmt);

        // encrypted HF check
        euint256 coll = _safeSlot(_eColl[msg.sender]);
        euint256 debt = _safeSlot(_eDebt[msg.sender]);

        ebool hfOk = TFHE.ge(
            TFHE.mul(coll, TFHE.asEuint256(BASIS_POINTS)),
            TFHE.mul(debt, TFHE.asEuint256(MIN_USER_HF_BP))
        );
        euint256 queued = TFHE.select(hfOk, amtEnc, TFHE.asEuint256(uint256(0)));
        TFHE.allow(queued, address(this));

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(queued);
        uint256 id = Gateway.requestDecryption(cts, this.borrowCallback.selector, 0, block.timestamp + 300, false);
        _pendingBorrow[id] = PendingBorrow(msg.sender, queued);
        emit BorrowQueued(msg.sender, id);
    }

    function borrowCallback(uint256 id, uint256 amt) external onlyGateway {
        PendingBorrow memory p = _pendingBorrow[id];
        delete _pendingBorrow[id];

        if (amt == 0) {
            return; // rejected
        }

        uint256 newDebt = totalDebt + amt;
        // Check vault health before proceeding
        _requireVaultHealthy(newDebt);

        // If we get here, the health check passed
        _eDebt[p.user] = TFHE.add(_eDebt[p.user], p.amountEnc);
        TFHE.allow(_eDebt[p.user], p.user);
        TFHE.allow(_eDebt[p.user], address(this));
        totalDebt = newDebt;

        pool.withdraw(address(debtToken), amt, address(this));
        debtToken.safeTransfer(p.user, amt);
        emit Borrowed(p.user, amt);
    }

    function repay(uint256 amt, einput encAmt, bytes calldata proofAmt) external whenNotPaused {
        require(amt > 0, "amt 0");

        euint256 amtEnc = TFHE.asEuint256(encAmt, proofAmt);
        TFHE.allow(amtEnc, address(this));
        euint256 debtEnc = _safeSlot(_eDebt[msg.sender]);
        TFHE.allow(debtEnc, address(this));

        // Compare debt and amount to determine if this is an over-repayment
        ebool isOverRepayment = TFHE.lt(debtEnc, amtEnc);
        euint256 result = TFHE.select(isOverRepayment, debtEnc, amtEnc);
        TFHE.allow(result, address(this));

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(result);
        uint256 id = Gateway.requestDecryption(cts, this.repayCallback.selector, 0, block.timestamp + 120, false);
        _pendingRepay[id] = msg.sender;
        emit RepayQueued(msg.sender, id);
    }

    function repayCallback(uint256 id, uint256 amt) external onlyGateway {
        address user = _pendingRepay[id];
        debtToken.safeTransferFrom(user, address(this), amt);
        delete _pendingRepay[id];

        // Update debt and total debt
        _eDebt[user] = TFHE.sub(_eDebt[user], TFHE.asEuint256(amt));
        TFHE.allow(_eDebt[user], user);
        TFHE.allow(_eDebt[user], address(this));
        totalDebt -= amt;

        emit Repaid(user, amt);
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
        return Gateway.toUint256(_eDebt[u]);
    }
    function encryptedCollOf(address u) external view returns (uint256) {
        return Gateway.toUint256(_eColl[u]);
    }
}
