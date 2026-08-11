/** `0x1234…cdef` — enough to compare at a glance, short enough for a navbar. */
export function truncateAddress(address: string, lead = 6, tail = 4): string {
  if (address.length <= lead + tail + 1) return address;
  return `${address.slice(0, lead)}…${address.slice(-tail)}`;
}

/**
 * Token ids are 256-bit hashes, so there is no short form that stays unique. Showing the head and
 * tail of the hex is honest about that: it is an identifier to recognise, not one to read.
 */
export function truncateTokenId(tokenId: bigint): string {
  const hex = `0x${tokenId.toString(16)}`;
  return truncateAddress(hex, 8, 6);
}
