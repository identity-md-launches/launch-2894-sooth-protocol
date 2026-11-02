// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Sooth Protocol token
/// @notice Fixed supply, 18 decimals, and ordinary ERC-20 transfers without fees.
/// @dev The deploying caller receives the entire supply. During a factory launch,
///      that caller is the factory. Deployment grants no administrative powers.
contract SoothToken is ERC20 {
    /// @notice One billion SOOTH, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Sooth Protocol", "SOOTH") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
