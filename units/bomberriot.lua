return { bomberriot = {
  name                = [[Phoenix]],
  description         = [[Saturation Napalm Bomber]],
  brakerate           = 0.4,
  builder             = false,
  buildPic            = [[bomberriot.png]],
  canFly              = true,
  canGuard            = true,
  canMove             = true,
  canPatrol           = true,
  canSubmerge         = false,
  category            = [[FIXEDWING]],
  collide             = false,
  collisionVolumeOffsets = [[0 0 -5]],
  collisionVolumeScales  = [[55 18 75]],
  collisionVolumeType    = [[ellipsoid]],
  selectionVolumeOffsets = [[0 0 0]],
  selectionVolumeScales  = [[108 27 108]],
  selectionVolumeType    = [[cylY]],
  corpse              = [[DEAD]],
  cruiseAltitude      = 160,

  customParams        = {
    modelradius    = [[10]],
    refuelturnradius = [[120]],
    reammoseconds = 8,
  },

  explodeAs           = [[GUNSHIPEX]],
  floater             = true,
  footprintX          = 4,
  footprintZ          = 4,
  health              = 1400,
  iconType            = [[bomberraider]],
  maxAcc              = 0.5,
  maxAileron          = 0.016,
  maxBank             = 0.72,
  maxElevator         = 0.02,
  maxRudder           = 0.0075,
  maxFuel             = 1000000,
  metalCost           = 460,
  noAutoFire          = false,
  noChaseCategory     = [[TERRAFORM FIXEDWING GUNSHIP SUB]],
  objectName          = [[firestorm.s3o]],
  script              = [[bomberriot.lua]],
  selfDestructAs      = [[GUNSHIPEX]],

  sfxtypes            = {

    explosiongenerators = {
      [[custom:BEAMWEAPON_MUZZLE_RED]],
      [[custom:light_red]],
      [[custom:light_green]],
    },

  },
  sightDistance       = 780,
  speed               = 243,
  turnRadius          = 160,
  workerTime          = 0,

  weapons             = {

    {
      def                = [[NAPALM]],
      badTargetCategory  = [[SWIM LAND SHIP HOVER GUNSHIP]],
      onlyTargetCategory = [[SWIM LAND SINK TURRET FLOAT SHIP HOVER GUNSHIP]],
    },

  },


  weaponDefs          = {

    NAPALM = {
      name                    = [[Napalm Bombs]],
      areaOfEffect            = 320,
      avoidFeature            = false,
      avoidFriendly           = false,
      burst                   = 18,
      burstrate               = 0.1,
      collideFeature          = false,
      collideFriendly         = false,
      craterBoost             = 0,
      craterMult              = 0,

      customParams              = {
        reammoseconds = "autogenerated in posts",
        reaim_time = 15, -- Fast update not required (maybe dangerous)
        setunitsonfire = "1",
        burntime = 360,
        gui_sprayangle = 0.32,
      },
      
      damage                  = {
        default = 40,
      },

      edgeEffectiveness       = 0.7,
      explosionGenerator      = [[custom:napalm_phoenix]],
      fireStarter             = 250,
      impulseBoost            = 0,
      impulseFactor           = 0.1,
      interceptedByShieldType = 1,
      model                   = [[wep_b_fabby.s3o]],
      myGravity               = 0.72,
      noSelfDamage            = true,
      reloadtime              = 1,
      soundHit                = [[weapon/burn_mixed]],
      soundStart              = [[weapon/bomb_drop_short]],
      sprayangle              = 15000, -- Maximum is 22500. Note that this has little effect due to near-zero launch speed.
      weaponType              = [[AircraftBomb]],
    },

  },


  featureDefs         = {

    DEAD  = {
      blocking         = true,
      featureDead      = [[HEAP]],
      footprintX       = 2,
      footprintZ       = 2,
      collisionVolumeOffsets = [[0 0 -5]],
      collisionVolumeScales  = [[55 15 70]],
      collisionVolumeType    = [[box]],
      object           = [[firestorm_dead.s3o]],
    },

    HEAP  = {
      blocking         = false,
      footprintX       = 2,
      footprintZ       = 2,
      object           = [[debris3x3c.s3o]],
    },

  },

} }
