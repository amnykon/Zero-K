return { striderhub = {
  name                          = [[Strider Hub]],
  description                   = [[Constructs Striders]],
  buildDistance                 = 300,
  builder                       = true,
  buildingGroundDecalDecaySpeed = 30,
  buildingGroundDecalSizeX      = 6,
  buildingGroundDecalSizeY      = 6,
  buildingGroundDecalType       = [[striderhub_aoplane.dds]],

  buildoptions                  = {
    [[athena]],
    [[striderantiheavy]],
    [[striderscorpion]],
    [[striderdante]],
    [[striderarty]],
    [[striderfunnelweb]],
    [[striderbantha]],
    [[striderdetriment]],
    [[shipheavyarty]],
    [[shipcarrier]],
    [[subtacmissile]],
  },

  buildPic                      = [[striderhub.png]],
  canGuard                      = true,
  canMove                       = false,
  canPatrol                     = true,
  cantBeTransported             = true,
  category                      = [[FLOAT UNARMED]],
  collisionVolumeOffsets        = [[0 0 0]],
  collisionVolumeScales         = [[70 70 70]],
  collisionVolumeType           = [[ellipsoid]],
  corpse                        = [[DEAD]],

  customParams                  = {
    neededlink     = 50,
    pylonrange     = 50,
    keeptooltip    = [[any string I want]],

    aimposoffset      = [[0 0 0]],
    midposoffset      = [[0 -10 0]],
    modelradius       = [[35]],
    isfakefactory     = [[1]],
    selection_rank    = [[2]],
    factorytab        = 1,
    shared_energy_gen = 1,
    like_structure    = 1,
    select_show_eco   = 1,
  },

  explodeAs                     = [[ESTOR_BUILDINGEX]],
  floater                       = true,
  footprintX                    = 4,
  footprintZ                    = 4,
  health                        = 2000,
  iconType                      = [[t3hub]],
  levelGround                   = false,
  maneuverleashlength           = [[380]],
  maxSlope                      = 15,
  metalCost                     = Shared.FACTORY_COST,
  movementClass                 = [[KBOT4]],
  noAutoFire                    = false,
  objectName                    = [[striderhub.s3o]],
  script                        = [[striderhub.lua]],
  selfDestructAs                = [[ESTOR_BUILDINGEX]],
  showNanoSpray                 = false,
  sightDistance                 = 380,
  upright                       = true,
  useBuildingGroundDecal        = true,
  workerTime                    = 10,

  featureDefs                   = {

    DEAD = {
      blocking         = false,
      featureDead      = [[HEAP]],
      footprintX       = 4,
      footprintZ       = 4,
      object           = [[striderhub_dead.s3o]],
    },


    HEAP = {
      blocking         = false,
      footprintX       = 4,
      footprintZ       = 4,
      object           = [[debris4x4a.s3o]],
    },

  },

} }
