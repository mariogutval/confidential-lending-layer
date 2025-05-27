// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract MockCompoundPool is IERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 public constant EXCHANGE_RATE = 1e18; // 1:1 exchange rate for simplicity

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    constructor(address _underlying) {
        underlying = IERC20(_underlying);
        name = string.concat("Compound ", IERC20(_underlying).name());
        symbol = string.concat("c", IERC20(_underlying).symbol());
    }

    function mint(uint256 amount) external returns (uint256) {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        return 0; // Success
    }

    function redeem(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        underlying.safeTransfer(msg.sender, amount);
        return 0; // Success
    }

    function borrow(uint256 amount) external returns (uint256) {
        // For testing, we'll mint the underlying token if needed
        uint256 balance = underlying.balanceOf(address(this));
        if (balance < amount) {
            IMintableERC20(address(underlying)).mint(address(this), amount - balance);
        }
        underlying.safeTransfer(msg.sender, amount);
        return 0; // Success
    }

    function repayBorrow(uint256 amount) external returns (uint256) {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        return 0; // Success
    }

    function exchangeRateStored() external pure returns (uint256) {
        return EXCHANGE_RATE;
    }

    // IERC20 implementation
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // Internal functions
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "transfer from zero");
        require(to != address(0), "transfer to zero");
        require(_balances[from] >= amount, "insufficient balance");

        _balances[from] -= amount;
        _balances[to] += amount;
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        require(from != address(0), "burn from zero");
        require(_balances[from] >= amount, "insufficient balance");
        _balances[from] -= amount;
        _totalSupply -= amount;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "approve from zero");
        require(spender != address(0), "approve to zero");
        _allowances[owner][spender] = amount;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        require(_allowances[owner][spender] >= amount, "insufficient allowance");
        _allowances[owner][spender] -= amount;
    }
} 