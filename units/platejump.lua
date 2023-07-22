return { platejump = {
  name                          = [[Jumpbot Plate]],
  description                   = [[Parallel Unit Production]],
  buildDistance                 = Shared.FACTORY_PLATE_RANGE,
  builder                       = true,
  buildingGroundDecalDecaySpeed = 30,
  buildingGroundDecalSizeX      = 10,
  buildingGroundDecalSizeY      = 10,
  buildingGroundDecalType       = [[platejump_aoplane.dds]],

  buildoptions                  = {
    [[jumpcon]],
    [[jumpscout]],
    [[jumpraid]],
    [[jumpblackhole]],
    [[jumpskirm]],
    [[jumpassault]],
    [[jumpsumo]],
    [[jumparty]],
    [[jumpaa]],
    [[jumpbomb]],
  },

  buildPic                      = [[platejump.png]],
  canMove                       = true,
  canPatrol                     = true,
  category                      = [[SINK UNARMED]],
  collisionVolumeOffsets        = [[0 28 -2]],
  collisionVolumeScales         = [[32 60 26]],
  collisionVolumeType           = [[box]],
  selectionVolumeOffsets        = [[0 15 28]],
  selectionVolumeScales         = [[70 40 96]],
  selectionVolumeType           = [[box]],
  corpse                        = [[DEAD]],

  customParams                  = {
    aimposoffset       = [[0 20 -32]],
    midposoffset       = [[0 0 -28]],
    canjump            = [[1]],
    no_jump_handling   = [[1]],
    sortName           = [[5]],
    modelradius        = [[50]],
    solid_factory      = [[3]],
    default_spacing    = 4,
    unstick_help       = 1,
    child_of_factory   = [[factoryjump]],
    buggeroff_offset   = 45,

    outline_x = 165,
    outline_y = 165,
    outline_yoff = 27.5,
  },

  explodeAs                     = [[FAC_PLATEEX]],
  footprintX                    = 5,
  footprintZ                    = 7,
  health                        = Shared.FACTORY_PLATE_HEALTH,
  iconType                      = [[padjumpjet]],
  maxSlope                      = 15,
  maxWaterDepth                 = 0,
  metalCost                     = Shared.FACTORY_PLATE_COST,
  moveState                     = 1,
  noAutoFire                    = false,
  objectName                    = [[plate_jump.s3o]],
  script                        = [[platejump.lua]],
  selfDestructAs                = [[FAC_PLATEEX]],
  showNanoSpray                 = false,
  sightDistance                 = 273,
  useBuildingGroundDecal        = true,
  workerTime                    = Shared.FACTORY_BUILDPOWER,
  yardMap                       = [[ooooo ooooo ooooo yyyyy yyyyy yyyyy yyyyy]],

  featureDefs                   = {

    DEAD  = {
      blocking         = true,
      featureDead      = [[HEAP]],
      footprintX       = 5,
      footprintZ       = 7,
      object           = [[plate_jump_dead.s3o]],
    },


    HEAP  = {
      blocking         = false,
      footprintX       = 5,
      footprintZ       = 7,
      object           = [[debris4x4c.s3o]],
    },

  },

} }
