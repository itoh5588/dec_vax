#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""mkmigprj.py - the MIG (mig_7series 4.2) project file for the DDR3L of
the Digilent Arty S7-50, for tcl/mig.tcl:

    mkmigprj.py mig_arty_s7.prj

The values (PLAN 7, daily report 2026-11-23 section 19): MT41K128M16XX-15E
(DDR3L, 1.35 V, x16, 256 MB), 3125 ps (320 MHz), PHY 4:1 (ui_clk 80 MHz),
system clock 160 MHz and reference clock 200 MHz from the fabric (No
Buffer), internal VREF, CL 5, CWL 5, BL8, RTT_NOM RZQ/6, native interface,
ROW_BANK_COLUMN, sys_rst active high. The pins are the board's wiring
(bank 34).
"""
import sys

PINS = [
    ("ddr3_addr[0]", "U2", "SSTL135"),
    ("ddr3_addr[1]", "R4", "SSTL135"),
    ("ddr3_addr[2]", "V2", "SSTL135"),
    ("ddr3_addr[3]", "V4", "SSTL135"),
    ("ddr3_addr[4]", "T3", "SSTL135"),
    ("ddr3_addr[5]", "R7", "SSTL135"),
    ("ddr3_addr[6]", "V6", "SSTL135"),
    ("ddr3_addr[7]", "T6", "SSTL135"),
    ("ddr3_addr[8]", "U7", "SSTL135"),
    ("ddr3_addr[9]", "V7", "SSTL135"),
    ("ddr3_addr[10]", "P6", "SSTL135"),
    ("ddr3_addr[11]", "T5", "SSTL135"),
    ("ddr3_addr[12]", "R6", "SSTL135"),
    ("ddr3_addr[13]", "U6", "SSTL135"),
    ("ddr3_ba[0]", "V5", "SSTL135"),
    ("ddr3_ba[1]", "T1", "SSTL135"),
    ("ddr3_ba[2]", "U3", "SSTL135"),
    ("ddr3_cas_n", "V3", "SSTL135"),
    ("ddr3_ck_n[0]", "T4", "DIFF_SSTL135"),
    ("ddr3_ck_p[0]", "R5", "DIFF_SSTL135"),
    ("ddr3_cke[0]", "T2", "SSTL135"),
    ("ddr3_cs_n[0]", "R3", "SSTL135"),
    ("ddr3_dm[0]", "K4", "SSTL135"),
    ("ddr3_dm[1]", "M3", "SSTL135"),
    ("ddr3_dq[0]", "K2", "SSTL135"),
    ("ddr3_dq[1]", "K3", "SSTL135"),
    ("ddr3_dq[2]", "L4", "SSTL135"),
    ("ddr3_dq[3]", "M6", "SSTL135"),
    ("ddr3_dq[4]", "K6", "SSTL135"),
    ("ddr3_dq[5]", "M4", "SSTL135"),
    ("ddr3_dq[6]", "L5", "SSTL135"),
    ("ddr3_dq[7]", "L6", "SSTL135"),
    ("ddr3_dq[8]", "N4", "SSTL135"),
    ("ddr3_dq[9]", "R1", "SSTL135"),
    ("ddr3_dq[10]", "N1", "SSTL135"),
    ("ddr3_dq[11]", "N5", "SSTL135"),
    ("ddr3_dq[12]", "M2", "SSTL135"),
    ("ddr3_dq[13]", "P1", "SSTL135"),
    ("ddr3_dq[14]", "M1", "SSTL135"),
    ("ddr3_dq[15]", "P2", "SSTL135"),
    ("ddr3_dqs_n[0]", "L1", "DIFF_SSTL135"),
    ("ddr3_dqs_n[1]", "N2", "DIFF_SSTL135"),
    ("ddr3_dqs_p[0]", "K1", "DIFF_SSTL135"),
    ("ddr3_dqs_p[1]", "N3", "DIFF_SSTL135"),
    ("ddr3_odt[0]", "P5", "SSTL135"),
    ("ddr3_ras_n", "U1", "SSTL135"),
    ("ddr3_reset_n", "J6", "SSTL135"),
    ("ddr3_we_n", "P7", "SSTL135"),
]

HEAD = """<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<Project NoOfControllers="1">
  <ModuleName>mig_ddr3</ModuleName>
  <dci_inouts_inputs>1</dci_inouts_inputs>
  <dci_inputs>1</dci_inputs>
  <Debug_En>OFF</Debug_En>
  <DataDepth_En>1024</DataDepth_En>
  <LowPower_En>ON</LowPower_En>
  <XADC_En>Disabled</XADC_En>
  <TargetFPGA>xc7s50-csga324/-1</TargetFPGA>
  <Version>4.2</Version>
  <SystemClock>No Buffer</SystemClock>
  <ReferenceClock>No Buffer</ReferenceClock>
  <SysResetPolarity>ACTIVE HIGH</SysResetPolarity>
  <BankSelectionFlag>FALSE</BankSelectionFlag>
  <InternalVref>1</InternalVref>
  <dci_hr_inouts_inputs>50 Ohms</dci_hr_inouts_inputs>
  <dci_cascade>0</dci_cascade>
  <Controller number="0">
    <MemoryDevice>DDR3_SDRAM/Components/MT41K128M16XX-15E</MemoryDevice>
    <TimePeriod>3125</TimePeriod>
    <VccAuxIO>1.8V</VccAuxIO>
    <PHYRatio>4:1</PHYRatio>
    <InputClkFreq>160</InputClkFreq>
    <UIExtraClocks>0</UIExtraClocks>
    <MMCM_VCO>640</MMCM_VCO>
    <MMCMClkOut0> 1.000</MMCMClkOut0>
    <MMCMClkOut1>1</MMCMClkOut1>
    <MMCMClkOut2>1</MMCMClkOut2>
    <MMCMClkOut3>1</MMCMClkOut3>
    <MMCMClkOut4>1</MMCMClkOut4>
    <DataWidth>16</DataWidth>
    <DeepMemory>1</DeepMemory>
    <DataMask>1</DataMask>
    <ECC>Disabled</ECC>
    <Ordering>Strict</Ordering>
    <BankMachineCnt>2</BankMachineCnt>
    <CustomPart>FALSE</CustomPart>
    <NewPartName></NewPartName>
    <RowAddress>14</RowAddress>
    <ColAddress>10</ColAddress>
    <BankAddress>3</BankAddress>
    <MemoryVoltage>1.35V</MemoryVoltage>
    <UserMemoryAddressMap>ROW_BANK_COLUMN</UserMemoryAddressMap>
    <PinSelection>
"""

TAIL = """    </PinSelection>
    <System_Control>
      <Pin Bank="Select Bank" PADName="No connect" name="sys_rst"/>
      <Pin Bank="Select Bank" PADName="No connect" name="init_calib_complete"/>
      <Pin Bank="Select Bank" PADName="No connect" name="tg_compare_error"/>
    </System_Control>
    <TimingParameters>
      <Parameters tcke="5.625" tfaw="45" tras="36" trcd="13.5" trefi="7.8" trfc="160" trp="13.5" trrd="7.5" trtp="7.5" twtr="7.5"/>
    </TimingParameters>
    <mrBurstLength name="Burst Length">8 - Fixed</mrBurstLength>
    <mrBurstType name="Read Burst Type and Length">Sequential</mrBurstType>
    <mrCasLatency name="CAS Latency">5</mrCasLatency>
    <mrMode name="Mode">Normal</mrMode>
    <mrDllReset name="DLL Reset">No</mrDllReset>
    <mrPdMode name="DLL control for precharge PD">Slow Exit</mrPdMode>
    <emrDllEnable name="DLL Enable">Enable</emrDllEnable>
    <emrOutputDriveStrength name="Output Driver Impedance Control">RZQ/6</emrOutputDriveStrength>
    <emrMirrorSelection name="Address Mirroring">Disable</emrMirrorSelection>
    <emrCSSelection name="Controller Chip Select Pin">Enable</emrCSSelection>
    <emrRTT name="RTT (nominal) - On Die Termination (ODT)">RZQ/6</emrRTT>
    <emrPosted name="Additive Latency (AL)">0</emrPosted>
    <emrOCD name="Write Leveling Enable">Disabled</emrOCD>
    <emrDQS name="TDQS enable">Enabled</emrDQS>
    <emrRDQS name="Qoff">Output Buffer Enabled</emrRDQS>
    <mr2PartialArraySelfRefresh name="Partial-Array Self Refresh">Full Array</mr2PartialArraySelfRefresh>
    <mr2CasWriteLatency name="CAS write latency">5</mr2CasWriteLatency>
    <mr2AutoSelfRefresh name="Auto Self Refresh">Enabled</mr2AutoSelfRefresh>
    <mr2SelfRefreshTempRange name="High Temparature Self Refresh Rate">Normal</mr2SelfRefreshTempRange>
    <mr2RTTWR name="RTT_WR - Dynamic On Die Termination (ODT)">Dynamic ODT off</mr2RTTWR>
    <PortInterface>NATIVE</PortInterface>
  </Controller>
</Project>
"""


def main():
    with open(sys.argv[1], 'w') as f:
        f.write(HEAD)
        for name, pad, std in PINS:
            f.write('      <Pin IN_TERM="" IOSTANDARD="%s" PADName="%s" SLEW="" '
                    'VCCAUX_IO="" name="%s"/>\n' % (std, pad, name))
        f.write(TAIL)
    return 0


if __name__ == '__main__':
    sys.exit(main())
