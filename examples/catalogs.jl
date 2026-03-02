# Hard-coded CAN message catalogs plus default channel wiring.
# Standard J1939 messages extracted from logs/canlog.log.

const VEHICLE_STATUS_MESSAGES = CP.CanMessage[

    # ── GPS (existing, SA=0x1C) ──────────────────────────────────────────

    CP.CanMessage(
        "GPSheading",
        CP.CanId(3, 0xFE, 0xE8, 0x1C),
        CP.Signal[
            CP.Signal("heading", 1, 1, 16, 1 / 128, 0.0),
            CP.Signal("speed", 3, 1, 16, 1 / 256, 0.0),
            CP.Signal("altitude", 7, 1, 16, 1 / 128, 0.0),
        ],
    ),
    CP.CanMessage(
        "GPSLatLong",
        CP.CanId(3, 0xFE, 0xF3, 0x1C),
        CP.Signal[
            CP.Signal("latitude", 1, 1, 32, 1.0e-7, -210.0),
            CP.Signal("longitude", 5, 1, 32, 1.0e-7, -210.0),
        ],
    ),

    # ── TSC1 – Torque/Speed Control 1 (PGN 0, PDU1) ─────────────────────
    # CAN ID 0x0C000003

    CP.CanMessage(
        "TSC1",
        CP.CanId(3, 0x00, 0x00, 0x03),
        CP.Signal[
            CP.Signal("EngOverrideCtrlMode", 1, 1, 2, 1.0, 0.0),
            CP.Signal("EngReqSpdCtrlCond", 1, 3, 2, 1.0, 0.0),
            CP.Signal("OverrideCtrlPriority", 1, 5, 2, 1.0, 0.0),
            CP.Signal("ReqSpeed_SpeedLimit", 2, 1, 16, 0.125, 0.0),
            CP.Signal("ReqTorque_TorqueLimit", 4, 1, 8, 1.0, -125.0),
        ],
    ),

    # ── ETC1 – Electronic Transmission Controller 1 (PGN 61441) ─────────
    # CAN IDs: 18F00100, 18F0010B, 18F00131

    CP.CanMessage(
        "ETC1",
        CP.CanId(6, 0xF0, 0x01, 0x00),
        CP.Signal[
            CP.Signal("OutputShaftSpeed", 2, 1, 16, 0.125, 0.0),
            CP.Signal("PercentClutchSlip", 4, 1, 8, 0.4, 0.0),
        ],
    ),
    CP.CanMessage(
        "ETC1_0x0B",
        CP.CanId(6, 0xF0, 0x01, 0x0B),
        CP.Signal[
            CP.Signal("OutputShaftSpeed", 2, 1, 16, 0.125, 0.0),
            CP.Signal("PercentClutchSlip", 4, 1, 8, 0.4, 0.0),
        ],
    ),
    CP.CanMessage(
        "ETC1_0x31",
        CP.CanId(6, 0xF0, 0x01, 0x31),
        CP.Signal[
            CP.Signal("OutputShaftSpeed", 2, 1, 16, 0.125, 0.0),
            CP.Signal("PercentClutchSlip", 4, 1, 8, 0.4, 0.0),
        ],
    ),

    # ── ETC2 – Electronic Transmission Controller 2 (PGN 61442) ─────────
    # CAN ID: 0CF00203

    CP.CanMessage(
        "ETC2",
        CP.CanId(3, 0xF0, 0x02, 0x03),
        CP.Signal[
            CP.Signal("SelectedGear", 1, 1, 8, 1.0, -125.0),
            CP.Signal("ActualGearRatio", 2, 1, 16, 0.001, 0.0),
            CP.Signal("CurrentGear", 4, 1, 8, 1.0, -125.0),
        ],
    ),

    # ── EEC2 – Electronic Engine Controller 2 (PGN 61443) ───────────────
    # CAN IDs: 0CF00300, 0CF00331

    CP.CanMessage(
        "EEC2",
        CP.CanId(3, 0xF0, 0x03, 0x00),
        CP.Signal[
            CP.Signal("AccelPedalPos1", 2, 1, 8, 0.4, 0.0),
            CP.Signal("EngPercentLoadCurSpd", 3, 1, 8, 1.0, 0.0),
            CP.Signal("RemoteAccelPedalPos", 4, 1, 8, 0.4, 0.0),
            CP.Signal("AccelPedalPos2", 5, 1, 8, 0.4, 0.0),
        ],
    ),
    CP.CanMessage(
        "EEC2_0x31",
        CP.CanId(3, 0xF0, 0x03, 0x31),
        CP.Signal[
            CP.Signal("AccelPedalPos1", 2, 1, 8, 0.4, 0.0),
            CP.Signal("EngPercentLoadCurSpd", 3, 1, 8, 1.0, 0.0),
            CP.Signal("RemoteAccelPedalPos", 4, 1, 8, 0.4, 0.0),
            CP.Signal("AccelPedalPos2", 5, 1, 8, 0.4, 0.0),
        ],
    ),

    # ── EEC1 – Electronic Engine Controller 1 (PGN 61444) ───────────────
    # CAN ID: 0CF00400

    CP.CanMessage(
        "EEC1",
        CP.CanId(3, 0xF0, 0x04, 0x00),
        CP.Signal[
            CP.Signal("EngTorqueMode", 1, 1, 4, 1.0, 0.0),
            CP.Signal("DriversDemandTorque", 2, 1, 8, 1.0, -125.0),
            CP.Signal("ActualEngTorque", 3, 1, 8, 1.0, -125.0),
            CP.Signal("EngineSpeed", 4, 1, 16, 0.125, 0.0),
            CP.Signal("SrcAddrCtrlDev", 6, 1, 8, 1.0, 0.0),
            CP.Signal("EngStarterMode", 7, 1, 4, 1.0, 0.0),
            CP.Signal("EngDemandTorque", 8, 1, 8, 1.0, -125.0),
        ],
    ),

    # ── ERC1 – Electronic Retarder Controller 1 (PGN 61445) ─────────────
    # CAN ID: 18F00503

    CP.CanMessage(
        "ERC1",
        CP.CanId(6, 0xF0, 0x05, 0x03),
        CP.Signal[
            CP.Signal("RetarderTorqueMode", 1, 1, 4, 1.0, 0.0),
            CP.Signal("ActualRetarderTorque", 2, 1, 8, 1.0, -125.0),
            CP.Signal("IntendedRetarderTorque", 3, 1, 8, 1.0, -125.0),
        ],
    ),

    # ── HRVD – High Resolution Vehicle Distance (PGN 65217) ─────────────
    # CAN IDs: 18FEC100, 18FEC131

    CP.CanMessage(
        "HRVD",
        CP.CanId(6, 0xFE, 0xC1, 0x00),
        CP.Signal[
            CP.Signal("HiResTotalVehicleDist", 1, 1, 32, 5.0, 0.0),
            CP.Signal("HiResTripDist", 5, 1, 32, 5.0, 0.0),
        ],
    ),
    CP.CanMessage(
        "HRVD_0x31",
        CP.CanId(6, 0xFE, 0xC1, 0x31),
        CP.Signal[
            CP.Signal("HiResTotalVehicleDist", 1, 1, 32, 5.0, 0.0),
            CP.Signal("HiResTripDist", 5, 1, 32, 5.0, 0.0),
        ],
    ),

    # ── DM1 – Active Diagnostic Trouble Codes (PGN 65226) ───────────────
    # CAN IDs: 18FECA00, 18FECA03, 18FECA0B, 18FECA31

    CP.CanMessage(
        "DM1_Engine",
        CP.CanId(6, 0xFE, 0xCA, 0x00),
        CP.Signal[
            CP.Signal("ProtectLamp", 1, 1, 2, 1.0, 0.0),
            CP.Signal("AmberWarningLamp", 1, 3, 2, 1.0, 0.0),
            CP.Signal("RedStopLamp", 1, 5, 2, 1.0, 0.0),
            CP.Signal("MalfunctionLamp", 1, 7, 2, 1.0, 0.0),
        ],
    ),
    CP.CanMessage(
        "DM1_Trans",
        CP.CanId(6, 0xFE, 0xCA, 0x03),
        CP.Signal[
            CP.Signal("ProtectLamp", 1, 1, 2, 1.0, 0.0),
            CP.Signal("AmberWarningLamp", 1, 3, 2, 1.0, 0.0),
            CP.Signal("RedStopLamp", 1, 5, 2, 1.0, 0.0),
            CP.Signal("MalfunctionLamp", 1, 7, 2, 1.0, 0.0),
        ],
    ),
    CP.CanMessage(
        "DM1_Brakes",
        CP.CanId(6, 0xFE, 0xCA, 0x0B),
        CP.Signal[
            CP.Signal("ProtectLamp", 1, 1, 2, 1.0, 0.0),
            CP.Signal("AmberWarningLamp", 1, 3, 2, 1.0, 0.0),
            CP.Signal("RedStopLamp", 1, 5, 2, 1.0, 0.0),
            CP.Signal("MalfunctionLamp", 1, 7, 2, 1.0, 0.0),
        ],
    ),
    CP.CanMessage(
        "DM1_BodyCtrl",
        CP.CanId(6, 0xFE, 0xCA, 0x31),
        CP.Signal[
            CP.Signal("ProtectLamp", 1, 1, 2, 1.0, 0.0),
            CP.Signal("AmberWarningLamp", 1, 3, 2, 1.0, 0.0),
            CP.Signal("RedStopLamp", 1, 5, 2, 1.0, 0.0),
            CP.Signal("MalfunctionLamp", 1, 7, 2, 1.0, 0.0),
        ],
    ),

    # ── EBC2 – Electronic Brake Controller 2 (PGN 65247) ────────────────
    # CAN ID: 18FEDF00

    CP.CanMessage(
        "EBC2",
        CP.CanId(6, 0xFE, 0xDF, 0x00),
        CP.Signal[
            CP.Signal("FrontAxleSpeed", 1, 1, 16, 1 / 256, 0.0),
            CP.Signal("RelativeSpeedFrontRear", 3, 1, 8, 1 / 16, -7.8125),
            CP.Signal("RelativeSpeedRearLR", 4, 1, 8, 1 / 16, -7.8125),
        ],
    ),

    # ── VD – Vehicle Distance (PGN 65248) ────────────────────────────────
    # CAN ID: 18FEE000

    CP.CanMessage(
        "VD",
        CP.CanId(6, 0xFE, 0xE0, 0x00),
        CP.Signal[
            CP.Signal("TotalVehicleDist", 1, 1, 32, 0.125, 0.0),
            CP.Signal("TripDist", 5, 1, 32, 0.125, 0.0),
        ],
    ),

    # ── HOURS – Engine Hours, Revolutions (PGN 65253) ────────────────────
    # CAN ID: 18FEE500

    CP.CanMessage(
        "HOURS",
        CP.CanId(6, 0xFE, 0xE5, 0x00),
        CP.Signal[
            CP.Signal("EngTotalHoursOfOp", 1, 1, 32, 0.05, 0.0),
            CP.Signal("EngTotalRevolutions", 5, 1, 32, 1000.0, 0.0),
        ],
    ),

    # ── FC – Fuel Consumption (PGN 65257) ────────────────────────────────
    # CAN ID: 18FEE900

    CP.CanMessage(
        "FC",
        CP.CanId(6, 0xFE, 0xE9, 0x00),
        CP.Signal[
            CP.Signal("TotalFuelUsed", 1, 1, 32, 0.5, 0.0),
            CP.Signal("TripFuel", 5, 1, 32, 0.5, 0.0),
        ],
    ),

    # ── ET1 – Engine Temperature 1 (PGN 65262) ──────────────────────────
    # CAN ID: 18FEEE00

    CP.CanMessage(
        "ET1",
        CP.CanId(6, 0xFE, 0xEE, 0x00),
        CP.Signal[
            CP.Signal("EngCoolantTemp", 1, 1, 8, 1.0, -40.0),
            CP.Signal("FuelTemp1", 2, 1, 8, 1.0, -40.0),
            CP.Signal("EngOilTemp1", 3, 1, 16, 0.03125, -273.0),
            CP.Signal("TurboOilTemp", 5, 1, 16, 0.03125, -273.0),
            CP.Signal("EngIntercoolerTemp", 7, 1, 8, 1.0, -40.0),
            CP.Signal("EngIntercoolerThermOpening", 8, 1, 8, 0.4, 0.0),
        ],
    ),

    # ── EFLP1 – Engine Fluid Level/Pressure 1 (PGN 65263) ───────────────
    # CAN ID: 18FEEF00

    CP.CanMessage(
        "EFLP1",
        CP.CanId(6, 0xFE, 0xEF, 0x00),
        CP.Signal[
            CP.Signal("FuelDeliveryPressure", 1, 1, 8, 4.0, 0.0),
            CP.Signal("ExtCrankcaseBlowbyPressure", 2, 1, 8, 0.05, 0.0),
            CP.Signal("EngOilLevel", 3, 1, 8, 0.4, 0.0),
            CP.Signal("EngOilPressure", 4, 1, 8, 4.0, 0.0),
            CP.Signal("CrankcasePressure", 5, 1, 16, 1 / 128, -250.0),
            CP.Signal("CoolantPressure", 7, 1, 8, 2.0, 0.0),
            CP.Signal("CoolantLevel", 8, 1, 8, 0.4, 0.0),
        ],
    ),

    # ── CCVS – Cruise Control/Vehicle Speed (PGN 65265) ──────────────────
    # CAN IDs: 18FEF100, 18FEF131

    CP.CanMessage(
        "CCVS",
        CP.CanId(6, 0xFE, 0xF1, 0x00),
        CP.Signal[
            CP.Signal("ParkingBrake", 1, 3, 2, 1.0, 0.0),
            CP.Signal("WheelBasedVehicleSpeed", 2, 1, 16, 1 / 256, 0.0),
            CP.Signal("CruiseCtrlActive", 4, 1, 2, 1.0, 0.0),
            CP.Signal("BrakeSwitch", 4, 5, 2, 1.0, 0.0),
            CP.Signal("ClutchSwitch", 4, 7, 2, 1.0, 0.0),
            CP.Signal("CruiseCtrlSetSpeed", 6, 1, 8, 1.0, 0.0),
        ],
    ),
    CP.CanMessage(
        "CCVS_0x31",
        CP.CanId(6, 0xFE, 0xF1, 0x31),
        CP.Signal[
            CP.Signal("ParkingBrake", 1, 3, 2, 1.0, 0.0),
            CP.Signal("WheelBasedVehicleSpeed", 2, 1, 16, 1 / 256, 0.0),
            CP.Signal("CruiseCtrlActive", 4, 1, 2, 1.0, 0.0),
            CP.Signal("BrakeSwitch", 4, 5, 2, 1.0, 0.0),
            CP.Signal("ClutchSwitch", 4, 7, 2, 1.0, 0.0),
            CP.Signal("CruiseCtrlSetSpeed", 6, 1, 8, 1.0, 0.0),
        ],
    ),

    # ── LFE – Fuel Economy, Liquid (PGN 65266) ──────────────────────────
    # CAN IDs: 18FEF200, 18FEF231

    CP.CanMessage(
        "LFE",
        CP.CanId(6, 0xFE, 0xF2, 0x00),
        CP.Signal[
            CP.Signal("FuelRate", 1, 1, 16, 0.05, 0.0),
            CP.Signal("InstFuelEconomy", 3, 1, 16, 1 / 512, 0.0),
            CP.Signal("AvgFuelEconomy", 5, 1, 16, 1 / 512, 0.0),
            CP.Signal("ThrottlePos", 7, 1, 8, 0.4, 0.0),
        ],
    ),
    CP.CanMessage(
        "LFE_0x31",
        CP.CanId(6, 0xFE, 0xF2, 0x31),
        CP.Signal[
            CP.Signal("FuelRate", 1, 1, 16, 0.05, 0.0),
            CP.Signal("InstFuelEconomy", 3, 1, 16, 1 / 512, 0.0),
            CP.Signal("AvgFuelEconomy", 5, 1, 16, 1 / 512, 0.0),
            CP.Signal("ThrottlePos", 7, 1, 8, 0.4, 0.0),
        ],
    ),

    # ── AMB – Ambient Conditions (PGN 65269) ─────────────────────────────
    # CAN ID: 18FEF500

    CP.CanMessage(
        "AMB",
        CP.CanId(6, 0xFE, 0xF5, 0x00),
        CP.Signal[
            CP.Signal("BarometricPressure", 1, 1, 8, 0.5, 0.0),
            CP.Signal("CabInteriorTemp", 2, 1, 16, 0.03125, -273.0),
            CP.Signal("AmbientAirTemp", 4, 1, 16, 0.03125, -273.0),
            CP.Signal("AirInletTemp", 6, 1, 8, 1.0, -40.0),
            CP.Signal("RoadSurfaceTemp", 7, 1, 16, 0.03125, -273.0),
        ],
    ),

    # ── IC1 – Inlet/Exhaust Conditions 1 (PGN 65270) ────────────────────
    # CAN ID: 18FEF600

    CP.CanMessage(
        "IC1",
        CP.CanId(6, 0xFE, 0xF6, 0x00),
        CP.Signal[
            CP.Signal("ParticulateTrapInletPressure", 1, 1, 8, 0.5, 0.0),
            CP.Signal("BoostPressure", 2, 1, 8, 2.0, 0.0),
            CP.Signal("IntakeManifoldTemp", 3, 1, 8, 1.0, -40.0),
            CP.Signal("AirInletPressure", 4, 1, 8, 2.0, 0.0),
            CP.Signal("AirFilterDiffPressure", 5, 1, 8, 0.05, 0.0),
            CP.Signal("ExhaustGasTemp", 6, 1, 16, 0.03125, -273.0),
            CP.Signal("CoolantFilterDiffPressure", 8, 1, 8, 0.5, 0.0),
        ],
    ),

    # ── VEP1 – Vehicle Electrical Power 1 (PGN 65271) ───────────────────
    # CAN IDs: 18FEF700, 18FEF731

    CP.CanMessage(
        "VEP1",
        CP.CanId(6, 0xFE, 0xF7, 0x00),
        CP.Signal[
            CP.Signal("NetBatteryCurrent", 1, 1, 16, 0.05, -1600.0),
            CP.Signal("AlternatorCurrent", 3, 1, 16, 0.05, 0.0),
            CP.Signal("AlternatorPotential", 5, 1, 16, 0.05, 0.0),
            CP.Signal("BatteryPotential", 7, 1, 16, 0.05, 0.0),
        ],
    ),
    CP.CanMessage(
        "VEP1_0x31",
        CP.CanId(6, 0xFE, 0xF7, 0x31),
        CP.Signal[
            CP.Signal("NetBatteryCurrent", 1, 1, 16, 0.05, -1600.0),
            CP.Signal("AlternatorCurrent", 3, 1, 16, 0.05, 0.0),
            CP.Signal("AlternatorPotential", 5, 1, 16, 0.05, 0.0),
            CP.Signal("BatteryPotential", 7, 1, 16, 0.05, 0.0),
        ],
    ),

    # ── TRF1 – Transmission Fluids 1 (PGN 65272) ────────────────────────
    # CAN IDs: 18FEF803, 18FEF831

    CP.CanMessage(
        "TRF1",
        CP.CanId(6, 0xFE, 0xF8, 0x03),
        CP.Signal[
            CP.Signal("ClutchPressure", 1, 1, 8, 16.0, 0.0),
            CP.Signal("TransOilLevel", 2, 1, 8, 0.4, 0.0),
            CP.Signal("TransFilterDiffPressure", 3, 1, 8, 2.0, 0.0),
            CP.Signal("TransOilPressure", 4, 1, 8, 16.0, 0.0),
            CP.Signal("TransOilTemp", 5, 1, 16, 0.03125, -273.0),
        ],
    ),
    CP.CanMessage(
        "TRF1_0x31",
        CP.CanId(6, 0xFE, 0xF8, 0x31),
        CP.Signal[
            CP.Signal("ClutchPressure", 1, 1, 8, 16.0, 0.0),
            CP.Signal("TransOilLevel", 2, 1, 8, 0.4, 0.0),
            CP.Signal("TransFilterDiffPressure", 3, 1, 8, 2.0, 0.0),
            CP.Signal("TransOilPressure", 4, 1, 8, 16.0, 0.0),
            CP.Signal("TransOilTemp", 5, 1, 16, 0.03125, -273.0),
        ],
    ),

    # ── DASH – Dash Display (PGN 65276) ──────────────────────────────────
    # CAN IDs: 18FEFC00, 18FEFC31

    CP.CanMessage(
        "DASH",
        CP.CanId(6, 0xFE, 0xFC, 0x00),
        CP.Signal[
            CP.Signal("WasherFluidLevel", 1, 1, 8, 0.4, 0.0),
            CP.Signal("FuelLevel1", 2, 1, 8, 0.4, 0.0),
            CP.Signal("FuelFilterDiffPressure", 3, 1, 8, 2.0, 0.0),
            CP.Signal("OilFilterDiffPressure", 4, 1, 8, 0.5, 0.0),
        ],
    ),
    CP.CanMessage(
        "DASH_0x31",
        CP.CanId(6, 0xFE, 0xFC, 0x31),
        CP.Signal[
            CP.Signal("WasherFluidLevel", 1, 1, 8, 0.4, 0.0),
            CP.Signal("FuelLevel1", 2, 1, 8, 0.4, 0.0),
            CP.Signal("FuelFilterDiffPressure", 3, 1, 8, 2.0, 0.0),
            CP.Signal("OilFilterDiffPressure", 4, 1, 8, 0.5, 0.0),
        ],
    ),

    # ── ASP – Air Supply Pressure (PGN 65198) ────────────────────────────
    # CAN ID: 18FEAE31

    CP.CanMessage(
        "ASP",
        CP.CanId(6, 0xFE, 0xAE, 0x31),
        CP.Signal[
            CP.Signal("PneumaticSupplyPressure", 1, 1, 8, 8.0, 0.0),
            CP.Signal("ServiceBrakeAirPressure1", 2, 1, 8, 8.0, 0.0),
            CP.Signal("ServiceBrakeAirPressure2", 3, 1, 8, 8.0, 0.0),
            CP.Signal("AuxEquipSupplyPressure", 4, 1, 8, 8.0, 0.0),
            CP.Signal("AirSuspensionSupplyPressure", 5, 1, 8, 8.0, 0.0),
        ],
    ),
]
