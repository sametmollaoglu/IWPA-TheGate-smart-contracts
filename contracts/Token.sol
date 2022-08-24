//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract Token is ERC20 {

    /// @param _name Name of the token
    /// @param _symbol Symbol for the token
    /// @param _supply Total token supply
    constructor (string memory _name, string memory _symbol, uint256 _supply)
        ERC20(_name, _symbol)
        {
            _mint(msg.sender, _supply);
        }
}