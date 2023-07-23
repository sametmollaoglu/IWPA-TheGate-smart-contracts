//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USDT is ERC20 {
    constructor() ERC20("Tether Token", "USDT") {
        _mint(0x38F11b6Df51a1F25015b271f679a25eFF5Aa08C8, 10000 * (10 ** decimals()));
        _mint(0xeCF9B2d5496de6654f0d76f5760215A205779852, 10000 * (10 ** decimals()));
        _mint(0xcd4F8c12a66150596BF89456B213F0eDc90b1308, 10000 * (10 ** decimals()));
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }

}
