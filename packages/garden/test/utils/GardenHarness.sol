// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Garden} from "../../src/Garden.sol";

/**
 * @dev Test only. Accrual credits a crystal when it acts. `act` credits it and does nothing else, so that the MANA
 *      tests can watch the credited balance and the remainder that waits for the next call. `actTwice` and
 *      `actWithoutSealing` are careless actions that no real function takes, so no real function can stand in for
 *      them, and the harness stays. The conservation handler drives the real actions: forging, attuning, the Arena
 *      and shattering.
 */
contract GardenHarness is Garden {
    constructor(Params memory params) Garden(params) {}

    /// The crystal acts and does nothing else: it is credited what it has accrued, as every action will credit it.
    function act(uint256 tokenId) external {
        Crystal storage crystal = _crystals[tokenId];
        crystal.mana = _seal(_accrue(crystal), ownerOf(tokenId));
    }

    /// An action that accrues twice, as a careless one might. The second accrual must find the first one's credit.
    function actTwice(uint256 tokenId) external {
        Crystal storage crystal = _crystals[tokenId];
        _accrue(crystal);
        crystal.mana = _seal(_accrue(crystal), ownerOf(tokenId));
    }

    /// An action that forgets to grant the owner the balance it ends with. It must not lock the crystal.
    function actWithoutSealing(uint256 tokenId) external {
        _accrue(_crystals[tokenId]);
    }
}
