//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract IWPA is ERC20 {
    constructor() ERC20("iwpa", "IWPA") {
        _mint(msg.sender, 1000000000000000000000000000);
    }
}
