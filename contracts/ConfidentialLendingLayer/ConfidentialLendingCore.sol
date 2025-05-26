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

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable }          from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";
import { console }           from "hardhat/console.sol";

import { TFHE, euint64, einput, ebool } from "fhevm/lib/TFHE.sol";
import { Gateway }                      from "fhevm/gateway/lib/Gateway.sol";
import { GatewayCaller }                from "fhevm/gateway/GatewayCaller.sol";
import { SepoliaZamaFHEVMConfig }       from "fhevm/config/ZamaFHEVMConfig.sol";
import { SepoliaZamaGatewayConfig }     from "fhevm/config/ZamaGatewayConfig.sol";

interface IAaveLikePool {
    function supply(address asset, uint256 amt, address onBehalf, uint16 refCode) external;
    function withdraw(address asset, uint256 amt, address to) external returns (uint256);
}

contract ConfidentialLendingCore is
    SepoliaZamaFHEVMConfig,
    SepoliaZamaGatewayConfig,
    GatewayCaller,
    ReentrancyGuard,
    Pausable,
    Ownable
{
    using SafeERC20 for IERC20;

    /* ─────────────────────────── CONSTANTS ────────────────────────── */
    uint256 public constant BASIS_POINTS   = 10_000;
    uint256 public constant MAX_VAULT_LTV  = 8_000;   // 80 %
    uint256 public constant MIN_USER_HF_BP = 11_500;  // 1.15×

    /* ───────────────────────────── TOKENS ─────────────────────────── */
    IERC20  public immutable collateralToken;
    IERC20  public immutable debtToken;
    IAaveLikePool public immutable pool;

    /* ───────────────────────────── STORAGE ────────────────────────── */
    mapping(address => euint64) private _eColl;
    mapping(address => euint64) private _eDebt;

    uint256 public totalCollateral;
    uint256 public totalDebt;

    struct PendingBorrow { address user; euint64 amountEnc; }
    mapping(uint256 => PendingBorrow) private _pendingBorrow;

    struct PendingRepay { address user; uint256 amount; }
    mapping(uint256 => PendingRepay) private _pendingRepay;

    /* ───────────────────────────── EVENTS ─────────────────────────── */
    event CollateralDeposited(address indexed user, uint256 amount);
    event BorrowQueued(address indexed user, uint256 reqId);
    event Borrowed(address indexed user, uint256 amount);
    event RepayQueued(address indexed user, uint256 reqId);
    event Repaid(address indexed user, uint256 amountBurned, uint256 refund);
    event Paused(); event Unpaused();

    /* ──────────────────────────── INIT ────────────────────────────── */
    constructor(address _coll, address _debt, address _pool) Ownable(msg.sender) {
        collateralToken = IERC20(_coll);
        debtToken       = IERC20(_debt);
        pool            = IAaveLikePool(_pool);
    }

    /* ─────────────────────────── HELPERS ──────────────────────────── */
    function _requireVaultHealthy(uint256 newDebt) internal view {
        require(newDebt * BASIS_POINTS <= totalCollateral * MAX_VAULT_LTV, "vault HF low");
    }

    function _safeSlot(euint64 s) internal returns (euint64) {
        if (TFHE.isInitialized(s)) return s;          // slot already has ACL
        euint64 zero = TFHE.asEuint64(uint64(0));     // fresh zero-ciphertext
        TFHE.allow(zero, address(this));              // whitelist the vault once
        return zero;
    }

    /* ────────────────────────── USER ACTIONS ───────────────────────── */
    function depositCollateral(uint256 amt, einput encZeroDebt, bytes calldata proofZeroDebt)
        external whenNotPaused nonReentrant
    {
        require(amt > 0, "amt 0");
        collateralToken.safeTransferFrom(msg.sender, address(this), amt);

        _eColl[msg.sender] = TFHE.add(_safeSlot(_eColl[msg.sender]), TFHE.asEuint64(amt));
        TFHE.allow(_eColl[msg.sender], msg.sender);
        TFHE.allow(_eColl[msg.sender], address(this));
        totalCollateral += amt;

        // decorrelate debt slot
        euint64 rnd = TFHE.asEuint64(encZeroDebt, proofZeroDebt);
        _eDebt[msg.sender] = TFHE.add(_safeSlot(_eDebt[msg.sender]), rnd);
        TFHE.allow(_eDebt[msg.sender], msg.sender);
        TFHE.allow(_eDebt[msg.sender], address(this));

        emit CollateralDeposited(msg.sender, amt);
    }

    function borrow(einput encAmt, bytes calldata proofAmt) external whenNotPaused nonReentrant {
        euint64 amtEnc = TFHE.asEuint64(encAmt, proofAmt);

        // encrypted HF check
        ebool hfOk = TFHE.ge(
            TFHE.mul(_safeSlot(_eColl[msg.sender]), TFHE.asEuint64(uint64(BASIS_POINTS))),
            TFHE.mul(_safeSlot(_eDebt[msg.sender]), TFHE.asEuint64(uint64(MIN_USER_HF_BP)))
        );
        euint64 queued = TFHE.select(hfOk, amtEnc, TFHE.asEuint64(uint64(0)));
        TFHE.allow(queued, address(this));

        uint256[] memory cts = new uint256[](1); cts[0] = Gateway.toUint256(queued);
        uint256 id = Gateway.requestDecryption(cts, this.borrowCallback.selector, 0, block.timestamp + 300, false);
        _pendingBorrow[id] = PendingBorrow(msg.sender, queued);
        emit BorrowQueued(msg.sender, id);
    }

    function borrowCallback(uint256 id, uint64 amt) external onlyGateway nonReentrant {        
        PendingBorrow memory p = _pendingBorrow[id]; 
        delete _pendingBorrow[id];
        
        if (amt == 0) {
            return; // rejected
        }

        uint256 newDebt = totalDebt + amt; 
        
        _requireVaultHealthy(newDebt);
        
        _eDebt[p.user] = TFHE.add(_eDebt[p.user], p.amountEnc); 
        TFHE.allow(_eDebt[p.user], p.user);
        TFHE.allow(_eDebt[p.user], address(this));
        totalDebt = newDebt;

        pool.withdraw(address(debtToken), amt, address(this));
        debtToken.safeTransfer(p.user, amt);
        emit Borrowed(p.user, amt);
    }

    function repay(uint256 amt, einput encAmt, bytes calldata proofAmt) external whenNotPaused nonReentrant {
        console.log("Repaying");
        require(amt > 0, "amt 0");
        debtToken.safeTransferFrom(msg.sender, address(this), amt);

        euint64 amtEnc = TFHE.asEuint64(encAmt, proofAmt);
        TFHE.allow(amtEnc, address(this));
        euint64 debtEnc = _safeSlot(_eDebt[msg.sender]);
        
        // Always use the repayment amount, handle refund in callback
        ebool canBurn = TFHE.ge(debtEnc, amtEnc);
        euint64 result = amtEnc;
        TFHE.allow(result, address(this));
        
        uint256[] memory cts = new uint256[](1); cts[0] = Gateway.toUint256(result);
        uint256 id = Gateway.requestDecryption(cts, this.repayCallback.selector, 0, block.timestamp + 120, false);
        _pendingRepay[id] = PendingRepay(msg.sender, amt);
        emit RepayQueued(msg.sender, id);
    }

    function repayCallback(uint256 id, bool ok) external onlyGateway nonReentrant {
        PendingRepay memory p = _pendingRepay[id];
        delete _pendingRepay[id];

        uint256 burn;
        uint256 refund = p.amount;

        if (ok) {
            // Debt ≥ amount ⇒ burn full amount and no refund
            burn = p.amount;
            refund = 0;
        } else {
            // Debt < amount ⇒ burn only debt amount and refund excess
            burn = totalDebt;
            console.log("p.amount", p.amount);
            console.log("burn", burn);
            refund = p.amount - burn;
        }

        // Update debt and total debt
        _eDebt[p.user] = TFHE.sub(_eDebt[p.user], TFHE.asEuint64(uint64(burn)));
        TFHE.allow(_eDebt[p.user], p.user);
        TFHE.allow(_eDebt[p.user], address(this));
        totalDebt -= burn;

        console.log("refund", refund);
        if (refund > 0) debtToken.safeTransfer(p.user, refund);
        emit Repaid(p.user, burn, refund);
    }

    /* ─────────────── ADMIN & VIEWS ─────────────── */
    function pause() external onlyOwner { _pause(); emit Paused(); }
    function unpause() external onlyOwner { _unpause(); emit Unpaused(); }

    function encryptedDebtOf(address u) external view returns (uint256) { return Gateway.toUint256(_eDebt[u]); }
    function encryptedCollOf(address u) external view returns (uint256) { return Gateway.toUint256(_eColl[u]); }
}
