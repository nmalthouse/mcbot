//Stairs:
//facing, north-south-west-esat
//half top-bottom
//shape, straight, inner-left, inner-right, outer-left, outer-right
//waterlogged true fals

//Information needed:
//block name
//list of property

pub const BlockInfo = struct {
    properties: []BlockProperty,
};

pub const BlockProperty = struct {
    pub const Property = union {
        pub const Face = enum { floor, wall, ceiling };
        pub const Facing4 = enum { north, south, west, east };
        pub const Facing6 = enum { north, east, south, west, up, down };
        pub const Facing5 = enum { down, north, south, west, east };
        pub const Powered = bool;
        pub const HalfA = enum { upper, lower };
        pub const HalfB = enum { top, bottom };
        pub const Hinge = enum { left, right };
        pub const Open = bool;
        pub const EastA = bool;
        pub const EastB = enum { none, low, tall };
        pub const EastC = enum { up, side, none };

        pub const WestA = bool;
        pub const WestB = enum { none, low, tall };
        pub const WestC = enum { up, side, none };

        pub const NorthA = bool;
        pub const NorthB = enum { none, low, tall };
        pub const NorthC = enum { up, side, none };

        pub const SouthA = bool;
        pub const SouthB = enum { none, low, tall };
        pub const SouthC = enum { up, side, none };
        pub const Waterlogged = bool;
        pub const InWall = bool;
        pub const Attached = bool;
        pub const Rotation: u8 = 16;
        pub const DistanceA: u8 = 7;
        pub const DistanceB: u8 = 8;
        pub const Persistant = bool;
        pub const Axis3 = enum { x, y, z };
        pub const Axis2 = enum { x, z };
        pub const stage: u8 = 2;
    };

    num_states: u8,
    property: Property,
};
