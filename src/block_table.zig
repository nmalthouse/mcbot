//Encoding block id information
//
//First:
//Ensure block states are mapped to block properties consistently.
//
//Build one large array of IdRange
//
//IdRange:
//lower: u16
//upper: u16
//ptr: block info entry
//
//BlockInfo array
//
//attached
//waterlogged etc
//block_name
//
//To find a block
//do a binary search on IdRange

pub const IdRange = struct {
    lower: u16,
    upper: u16,
};

pub const BlockInfo = struct {
    properties: []BlockProperty,
};

pub const BlockProperty = union {};
