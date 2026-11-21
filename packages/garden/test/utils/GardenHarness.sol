// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Garden} from "../../src/Garden.sol";

/**
 * @dev Test only. Accrual credits a crystal when it acts, and in T03 the only action is shattering, which leaves
 *      nothing to observe afterwards. `act` stands in for the actions to come (attune, the Arena), so that the
 *      tests can watch the credited balance and the remainder that waits for the next call. Once T04 and T05 bring
 *      the real actions, the tests should move to them and this harness should go.
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
}
