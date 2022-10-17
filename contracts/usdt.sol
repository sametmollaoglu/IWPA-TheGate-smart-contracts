//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract usdt is ERC20 {
    /// @param _name Name of the token
    /// @param _symbol Symbol for the token
    /// @param _supply Total token supply
    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _supply
    ) ERC20(_name, _symbol) {
        _mint(0x5B38Da6a701c568545dCfcB03FcB875f56beddC4, _supply / 4);
        _mint(0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2, _supply / 4);
        _mint(0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db, _supply / 4);
        _mint(0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB, _supply / 4);
    }
}
