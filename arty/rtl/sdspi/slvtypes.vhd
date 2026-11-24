-- SPDX-License-Identifier: BSD-2-Clause
-- Copyright (c) 2026 Akio Itoh
--
-- slvtypes.vhd - the few std_logic subtypes sdspi_ctl.vhd and sdspi_phy.vhd
-- use, under the package name they expect (work.slvtypes). Written for
-- this project; only these names are defined.

library ieee;
use ieee.std_logic_1164.all;

package slvtypes is
  subtype slbit is std_logic;
  subtype slv   is std_logic_vector;
  subtype slv3  is std_logic_vector( 2 downto 0);
  subtype slv7  is std_logic_vector( 6 downto 0);
  subtype slv8  is std_logic_vector( 7 downto 0);
  subtype slv16 is std_logic_vector(15 downto 0);
  subtype slv32 is std_logic_vector(31 downto 0);
end package slvtypes;
