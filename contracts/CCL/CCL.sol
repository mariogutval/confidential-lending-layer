// SPDX‑License‑Identifier: MIT
pragma solidity 0.8.24;

import {IERC20}  from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TFHE, einput, euint64} from "fhevm/lib/TFHE.sol";
import {Gateway} from "fhevm/gateway/lib/Gateway.sol";

contract ConfidentialLendingCore {
    using TFHE for euint64;
    
    IERC20 public immutable underlying;      // e.g. USDC
    IERC20 public immutable collateral;      // e.g. WETH or cWETH
    address public immutable protocolPool;   // Aave Pool or Comet

    /// encrypted borrow balance per user
    mapping(address => euint64) private _eDebt;
    /// encrypted collateral (optional – useful for cross‑asset LTV maths)
    mapping(address => euint64) private _eColl;

    /* ------------------------------------------------- *
     *                 Collateral deposit                *
     * ------------------------------------------------- */
    function depositCollateral(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
        _eColl[msg.sender] = TFHE.add(
            _eColl[msg.sender],
            TFHE.asEuint64(amount)
        );
        // supply to lending pool
        collateral.approve(protocolPool, amount);
        // Pool.deposit(collateral, amount, address(this), 0)
    }

    /* ------------------------------------------------- *
     *              Confidential borrowing               *
     * ------------------------------------------------- */
    /// @param encRequestedLTV ciphertext of the % LTV (0‑1e4 basis points)
    function borrow(einput encRequestedLTV, bytes calldata inputProof) external {
        euint64 reqLTVbp = TFHE.asEuint64(encRequestedLTV, inputProof);     // encrypted input
        euint64 coll = _eColl[msg.sender];

        // maxLoan = collateral * LTV / 10000
        euint64 maxLoan = TFHE.div(TFHE.mul(coll, reqLTVbp), 10000);

        // update encrypted debt
        _eDebt[msg.sender] = TFHE.add(_eDebt[msg.sender], maxLoan);

        // Request decryption through the Gateway
        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(maxLoan);
        Gateway.requestDecryption(cts, this.callbackBorrow.selector, 0, block.timestamp + 100, false);
    }

    /// @notice Callback function for borrow decryption
    /// @param requestID The ID of the decryption request
    /// @param decryptedAmount The decrypted loan amount
    function callbackBorrow(uint256 requestID, uint64 decryptedAmount) external {
        // pull liquidity from pool and send to user
        // Pool.withdraw(underlying, decryptedAmount, msg.sender)
        underlying.transfer(msg.sender, decryptedAmount);  // optional wrapper
    }

    /* ------------------------------------------------- *
     *                 Confidential views                *
     * ------------------------------------------------- */
    function encryptedDebtOf(address user) external view returns (uint256) {
        return Gateway.toUint256(_eDebt[user]);   // front‑end can decrypt
    }
}
