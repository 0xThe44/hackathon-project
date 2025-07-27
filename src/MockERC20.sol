    // SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    //function balanceOf(address) public pure override returns (uint256) {
    //    return 1000; // Фейковый баланс
    //}
}
