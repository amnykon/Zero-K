return { plategunship = {
  name                          = [[Gunship Plate]],
  description                   = [[Parallel Unit Production]],
  buildDistance                 = Shared.FACTORY_PLATE_RANGE,
  builder                       = true,
  buildingGroundDecalDecaySpeed = 30,
  buildingGroundDecalSizeX      = 8,
  buildingGroundDecalSizeY      = 8,
  buildingGroundDecalType       = [[plategunship_aoplane.dds]],

  buildoptions                  = {
    [[gunshipcon]],
    [[gunshipbomb]],
    [[gunshipemp]],
    [[gunshipraid]],
    [[gunshipskirm]],
    [[gunshipheavyskirm]],
    [[gunshipassault]],
    [[gunshipkrow]],
    [[gunshipaa]],
    [[gunshiptrans]],
    [[gunshipheavytrans]],
  },

  buildPic                      = [[plategunship.png]],
  canMove                       = true,
  canPatrol                     = true,
  category                      = [[FLOAT UNARMED]],
  collisionVolumeOffsets        = [[0 0 0]],
  collisionVolumeScales         = [[74 74 74]],
  collisionVolumeType           = [[ellipsoid]],
  selectionVolumeOffsets        = [[0 15 0]],
  selectionVolumeScales         = [[70 40 70]],
  selectionVolumeType           = [[box]],
  corpse                        = [[DEAD]],

  customParams                  = {
    aimposoffset       = [[0 10 0]],
    landflystate       = [[0]],
    factory_land_state = 0,
    sortName           = [[3]],
    modelradius        = [[43]],
    default_spacing    = 4,
    child_of_factory   = [[factorygunship]],
    buggeroff_offset   = 0,

    outline_x = 165,
    outline_y = 165,
    outline_yoff = 27.5,
  },

  explodeAs                     = [[FAC_PLATEEX]],
  footprintX                    = 5,
  footprintZ                    = 5,
  health                        = Shared.FACTORY_PLATE_HEALTH,
  iconType                      = [[padgunship]],
  maxSlope                      = 15,
  metalCost                     = Shared.FACTORY_PLATE_COST,
  moveState                     = 1,
  noAutoFire                    = false,
  objectName                    = [[plate_gunship.s3o]],
  script                        = [[plategunship.lua]],
  selfDestructAs                = [[FAC_PLATEEX]],
  showNanoSpray                 = false,
  sightDistance                 = 273,
  useBuildingGroundDecal        = true,
  waterline                     = 0,
  workerTime                    = Shared.FACTORY_BUILDPOWER,
  yardMap                       = [[yoooy ooooo ooooo ooooo yoooy]],

  featureDefs                   = {

    DEAD  = {
      blocking         = true,
      featureDead      = [[HEAP]],
      footprintX       = 5,
      footprintZ       = 5,
      object           = [[plate_gunship_dead.s3o]],
    },


    HEAP  = {
      blocking         = false,
      footprintX       = 5,
      footprintZ       = 5,
      object           = [[debris4x4c.s3o]],
    },

  },

} }
