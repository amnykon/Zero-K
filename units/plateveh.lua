return { plateveh = {
  name                          = [[Rover Plate]],
  description                   = [[Parallel Unit Production]],
  buildDistance                 = Shared.FACTORY_PLATE_RANGE,
  builder                       = true,
  buildingGroundDecalDecaySpeed = 30,
  buildingGroundDecalSizeX      = 9,
  buildingGroundDecalSizeY      = 9,
  buildingGroundDecalType       = [[plateveh_aoplane.dds]],

  buildoptions                  = {
    [[vehcon]],
    [[vehscout]],
    [[vehraid]],
    [[vehsupport]],
    [[vehriot]],
    [[vehassault]],
    [[vehcapture]],
    [[veharty]],
    [[vehheavyarty]],
    [[vehaa]],
  },

  buildPic                      = [[plateveh.png]],
  canMove                       = true,
  canPatrol                     = true,
  category                      = [[SINK UNARMED]],
  collisionVolumeOffsets        = [[0 0 0]],
  collisionVolumeScales         = [[70 55 36]],
  collisionVolumeType           = [[ellipsoid]],
  selectionVolumeOffsets        = [[0 15 26]],
  selectionVolumeScales         = [[80 40 80]],
  selectionVolumeType           = [[box]],
  corpse                        = [[DEAD]],

  customParams                  = {
    sortName           = [[2]],
    default_spacing    = 4,
    solid_factory      = 2,
    aimposoffset       = [[0 15 -26]],
    midposoffset       = [[0 0 -26]],
    modelradius        = [[50]],
    unstick_help       = 1,
    child_of_factory   = [[factoryveh]],

    outline_x = 165,
    outline_y = 165,
    outline_yoff = 27.5,
  },

  explodeAs                     = [[FAC_PLATEEX]],
  footprintX                    = 6,
  footprintZ                    = 6,
  health                        = Shared.FACTORY_PLATE_HEALTH,
  iconType                      = [[padveh]],
  levelGround                   = false,
  maxSlope                      = 15,
  maxWaterDepth                 = 0,
  metalCost                     = Shared.FACTORY_PLATE_COST,
  moveState                     = 1,
  noAutoFire                    = false,
  objectName                    = [[plate_veh.s3o]],
  script                        = [[plateveh.lua]],
  selfDestructAs                = [[FAC_PLATEEX]],
  showNanoSpray                 = false,
  sightDistance                 = 273,
  useBuildingGroundDecal        = true,
  workerTime                    = Shared.FACTORY_BUILDPOWER,
  yardMap                       = "oooooo oooooo yyyyyy yyyyyy yyyyyy yyyyyy",

  featureDefs                   = {

    DEAD  = {
      blocking         = true,
      featureDead      = [[HEAP]],
      footprintX       = 6,
      footprintZ       = 6,
      object           = [[plate_veh_dead.s3o]],
      collisionVolumeOffsets = [[0 0 -20]],
      collisionVolumeScales  = [[110 35 75]],
      collisionVolumeType    = [[box]],
    },


    HEAP  = {
      blocking         = false,
      footprintX       = 6,
      footprintZ       = 6,
      object           = [[debris4x4c.s3o]],
    },

  },

} }
