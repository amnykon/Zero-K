return { energypylon = {
  name                          = [[Energy Pylon]],
  description                   = [[Extends overdrive grid]],
  activateWhenBuilt             = true,
  builder                       = false,
  buildingGroundDecalDecaySpeed = 30,
  buildingGroundDecalSizeX      = 5,
  buildingGroundDecalSizeY      = 5,
  buildingGroundDecalType       = [[energypylon_aoplane.dds]],
  buildPic                      = [[energypylon.png]],
  category                      = [[SINK UNARMED]],
  collisionVolumeOffsets        = [[0 0 0]],
  collisionVolumeScales         = [[42 42 42]],
  collisionVolumeType           = [[cylY]],
  selectionVolumeOffsets        = [[0 0 0]],
  selectionVolumeScales         = [[46 38 46]],
  selectionVolumeType           = [[cylY]],
  corpse                        = [[DEAD]],

  customParams                  = {
    pylonrange = 500,
    aimposoffset   = [[0 0 0]],
    midposoffset   = [[0 -6 0]],
    modelradius    = [[24]],
    removewait     = 1,
    removestop     = 1,
    default_spacing = 41, -- Diagonal connection.
    selectionscalemult = 1.15,
    stats_show_death_explosion = 1,
  },

  explodeAs                     = [[ESTOR_BUILDINGEX]],
  footprintX                    = 3,
  footprintZ                    = 3,
  health                        = 1000,
  iconType                      = [[pylon]],
  levelGround                   = false,
  maxSlope                      = 18,
  metalCost                     = 200,
  noAutoFire                    = false,
  objectName                    = [[armestor.s3o]],
  script                        = "energypylon.lua",
  selfDestructAs                = [[ESTOR_BUILDINGEX]],
  sightDistance                 = 273,
  useBuildingGroundDecal        = true,
  yardMap                       = [[ooo ooo ooo]],

  featureDefs                   = {

    DEAD  = {
      blocking         = true,
      collisionVolumeScales = [[42 42 42]],
      collisionVolumeType   = [[cylY]],
      featureDead      = [[HEAP]],
      footprintX       = 3,
      footprintZ       = 3,
      object           = [[ARMESTOR_DEAD.s3o]],
    },

    HEAP  = {
      blocking         = false,
      footprintX       = 3,
      footprintZ       = 3,
      object           = [[debris4x4b.s3o]],
    },

  },

} }
