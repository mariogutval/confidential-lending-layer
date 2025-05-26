  // SPDX-License-Identifier: MIT
  pragma solidity 0.8.24;
  /**
   * @title MockPool
   * @notice Ultra‑light stub that fulfils the IAaveLikePool interface used by
   *         `ConfidentialLendingCore` unit‑tests.  It deliberately contains
   *         *no* interest logic, accounting or risk checks — it simply acts as
   *         an infinite liquidity well so tests can focus on the core’s FHE
   *         paths.
   *
   * Behaviour:
   *   • `supply()` pulls ERC‑20 tokens from the caller into this contract.
   *   • `withdraw()` mints the requested amount on‑the‑fly **if** the token
   *     exposes a `mint(address,uint256)` function (true for `MockERC20`) —
   *     otherwise it transfers whatever balance it owns, capping at `amt`.
   */
  
  import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
  import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
  
  interface IMintableERC20 is IERC20 {
      function mint(address to, uint256 amount) external;
  }
  
  contract MockPool {
      using SafeERC20 for IERC20;
  
      IERC20 public immutable collateralToken;
      IERC20 public immutable debtToken;
  
      constructor(address _coll, address _debt) {
          collateralToken = IERC20(_coll);
          debtToken       = IERC20(_debt);
      }
  
      /**
       * @dev Mimics Aave’s `supply`: pulls tokens into the pool, ignores refCode.
       */
      function supply(address asset, uint256 amt, address /*onBehalfOf*/, uint16 /*refCode*/) external {
          IERC20(asset).safeTransferFrom(msg.sender, address(this), amt);
      }
  
      /**
       * @dev Mimics Aave’s `withdraw`: returns `amt` tokens to caller. If the
       *      pool lacks balance and the token is mintable (our MockERC20), it
       *      simply mints the shortfall so unit tests never fail on liquidity.
       * @return actuallyWithdrawn the amount sent out (always == amt in tests)
       */
      function withdraw(address asset, uint256 amt, address to) external returns (uint256 actuallyWithdrawn) {
          IERC20 tok = IERC20(asset);
          uint256 bal = tok.balanceOf(address(this));
  
          if (bal < amt) {
              // try minting the shortfall (works for MockERC20)
              uint256 shortfall = amt - bal;
              try IMintableERC20(asset).mint(address(this), shortfall) {
                  bal = amt; // now fully liquid
              } catch {
                  // cannot mint; cap withdrawal at available balance
                  amt = bal;
              }
          }
  
          tok.safeTransfer(to, amt);
          return amt;
      }
  }
