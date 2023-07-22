return { tankaa = {
  name                   = [[Ettin]],
  description            = [[Flak Anti-Air Tank]],
  acceleration           = 0.36,
  brakeRate              = 1.8,
  builder                = false,
  buildPic               = [[tankaa.png]],
  canGuard               = true,
  canMove                = true,
  canPatrol              = true,
  category               = [[LAND]],
  collisionVolumeOffsets = [[0 0 0]],
  collisionVolumeScales  = [[38 52 38]],
  collisionVolumeType    = [[cylY]],
  corpse                 = [[DEAD]],

  customParams           = {
    bait_level_default = 0,
    modelradius    = [[19]],
  },

  explodeAs              = [[BIG_UNITEX]],
  footprintX             = 3,
  footprintZ             = 3,
  health                 = 1400,
  iconType               = [[tankaa]],
  leaveTracks            = true,
  maneuverleashlength    = [[30]],
  maxSlope               = 18,
  maxWaterDepth          = 22,
  metalCost              = 500,
  movementClass          = [[TANK3]],
  moveState              = 0,
  noAutoFire             = false,
  noChaseCategory        = [[TERRAFORM LAND SINK TURRET SHIP SATELLITE SWIM FLOAT SUB HOVER]],
  objectName             = [[corsent.s3o]],
  script                 = [[tankaa.lua]],
  selfDestructAs         = [[BIG_UNITEX]],
  
  sfxtypes               = {

  explosiongenerators = {
      [[custom:HEAVY_CANNON_MUZZLE]],
    },

  },
  sightDistance          = 660,
  speed                  = 96,
  trackOffset            = 6,
  trackStrength          = 5,
  trackStretch           = 1,
  trackType              = [[StdTank]],
  trackWidth             = 38,
  turninplace            = 0,
  turnRate               = 1044,
  upright                = false,
  workerTime             = 0,

  weapons                = {

    {
      def                = [[FLAK]],
      --badTargetCategory  = [[FIXEDWING]],
      onlyTargetCategory = [[FIXEDWING GUNSHIP]],
    },

  },


  weaponDefs             = {

    FLAK = {
      name                    = [[Flak Cannon]],
      accuracy                = 100,
      areaOfEffect            = 64,
      burnblow                = true,
      canattackground         = false,
      cegTag                  = [[flak_trail]],
      craterBoost             = 0,
      craterMult              = 0,
      cylinderTargeting       = 1,

      customParams              = {
        reaim_time = 1, -- looks silly when rotating otherwise (high turret and body turn rates)
        isaa = [[1]],
        light_radius = 0,
      },

      damage                  = {
        default = 9,
        planes  = 90,
      },

      edgeEffectiveness       = 0.85,
      explosionGenerator      = [[custom:flakplosion]],
      impulseBoost            = 0,
      impulseFactor           = 0,
      interceptedByShieldType = 1,
      noSelfDamage            = true,
      range                   = 900,
      reloadtime              = 0.4,
      size                    = 0.01,
      soundHit                = [[weapon/flak_hit]],
      soundStart              = [[weapon/flak_fire]],
      turret                  = true,
      weaponType              = [[Cannon]],
      weaponVelocity          = 2000,
    },

  },


  featureDefs            = {

    DEAD  = {
      blocking         = true,
      featureDead      = [[HEAP]],
      footprintX       = 2,
      footprintZ       = 2,
      object           = [[corsent_dead.s3o]],
    },


    HEAP  = {
      blocking         = false,
      footprintX       = 2,
      footprintZ       = 2,
      object           = [[debris2x2a.s3o]],
    },

  },

} }
