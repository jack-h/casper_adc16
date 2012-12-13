require 'rubygems'
require 'katcp'

class ADC16 < KATCP::RoachClient
  DEVICE_TYPEMAP = {
    :adc16_controller => :bram,
    :snap_a_bram => :bram,
    :snap_b_bram => :bram,
    :snap_c_bram => :bram,
    :snap_d_bram => :bram
  }

  def device_typemap
    DEVICE_TYPEMAP
  end

  def initialize(*args)
    super(*args)
    @chip_select = 0b1111
  end

  # 4-bits of chip select values
  attr_accessor :chip_select
  alias :cs  :chip_select
  alias :cs= :chip_select=

  # ======================================= #
  # ADC0 3-Wire Register Bits               #
  # ======================================= #
  # C = SCLK (clock)                        #
  # D = SDATA (data)                        #
  # 0 = CSN1 (chip select 1)                #
  # 1 = CSN2 (chip select 2)                #
  # 2 = CSN3 (chip select 3)                #
  # 3 = CSN4 (chip select 4)                #
  # ======================================= #
  # |<-- MSb                       LSb -->| #
  # 0000_0000_0011_1111_1111_2222_2222_2233 #
  # 0123_4567_8901_2345_6789_0123_4567_8901 #
  # C--- ---- ---- ---- ---- ---- ---- ---- #
  # -D-- ---- ---- ---- ---- ---- ---- ---- #
  # --1- ---- ---- ---- ---- ---- ---- ---- #
  # ---2 ---- ---- ---- ---- ---- ---- ---- #
  # ---- 3--- ---- ---- ---- ---- ---- ---- #
  # ---- -4-- ---- ---- ---- ---- ---- ---- #
  # ======================================= #

  SCL = 1<<31
  SDA_SHIFT = 30
  CSN_SHIFT = 26
  IDLE_3WIRE = 0x3c00_0000

  def send_3wire_bit(bit)
    # Clock low, data and chip selects set accordingly
    adc16_controller[0] = ((  bit         &     1) << SDA_SHIFT) |
                          (((~chip_select)&0b1111) << CSN_SHIFT)
    # Clock high, data and chip selects set accordingly
    adc16_controller[0] = ((  bit         &     1) << SDA_SHIFT) |
                          (((~chip_select)&0b1111) << CSN_SHIFT) |
                          SCL
  end

  def setreg(addr, val)
    adc16_controller[0] = IDLE_3WIRE
    7.downto(0) {|i| send_3wire_bit(addr>>i)}
    15.downto(0) {|i| send_3wire_bit(val>>i)}
    adc16_controller[0] = IDLE_3WIRE
    self
  end

  def adc_reset
    setreg(0x00, 0x0001) # reset
  end

  def adc_power_cycle
    setreg(0x0f, 0x0200) # Powerdown
    setreg(0x0f, 0x0000) # Powerup
  end

  def adc_init
    raise 'FPGA not programmed' unless programmed?
    adc_reset
    adc_power_cycle
    progdev self.opts[:bof] if self.opts[:bof]
  end

  # Set output data endian-ness and binary format.  If +msb_invert+ is true,
  # then invert msb (i.e. output 2's complement (else straight offset binary).
  # If +msb_first+ is true, then output msb first (else lsb first).
  def data_format(invert_msb=false, msb_first=false)
    val = 0x0000
    val |= invert_msb ? 4 : 0
    val |= msb_first ? 8 : 0
    setreg(0x46, val)
  end

  # +ptn+ can be any of:
  #
  #   :ramp            Ramp pattern 0-255
  #   :deskew (:eye)   Deskew pattern (01010101)
  #   :sync (:frame)   Sync pattern (11110000)
  #   :custom1         Custom1 pattern
  #   :custom2         Custom2 pattern
  #   :dual            Dual custom pattern
  #   :none            No pattern
  #
  # Default is :ramp.  Any value other than shown above is the same as :none.
  def enable_pattern(ptn=:ramp)
    setreg(0x25, 0x0000)
    setreg(0x45, 0x0000)
    case ptn
    when :ramp;           setreg(0x25, 0x0040)
    when :deskew, :eye;   setreg(0x45, 0x0001)
    when :sync, :frame;   setreg(0x45, 0x0002)
    when :custom;         setreg(0x25, 0x0010)
    when :dual;           setreg(0x25, 0x0020)
    end
  end

  def clear_pattern;  enable_pattern :none;   end
  def ramp_pattern;   enable_pattern :ramp;   end
  def deskew_pattern; enable_pattern :deskew; end
  def sync_pattern;   enable_pattern :sync;   end
  def custom_pattern; enable_pattern :custom; end
  def dual_pattern;   enable_pattern :dual;   end
  def no_pattern;     enable_pattern :none;   end

  # Set the custom bits 1 from the lowest 8 bits of +bits+.
  def custom1=(bits)
    setreg(0x26, (bits&0xff) << 8)
  end

  # Set the custom bits 2 from the lowest 8 bits of +bits+.
  def custom2=(bits)
    setreg(0x27, (bits&0xff) << 8)
  end

  # ======================================= #
  # ADC0 Control Register Bits              #
  # ======================================= #
  # D = Delay RST                           #
  # T = Delay Tap                           #
  # B = ISERDES Bit Slip                    #
  # P = Load Phase Set                      #
  # R = Reset                               #
  # ======================================= #
  # |<-- MSb                       LSb -->| #
  # 0000 0000 0011 1111 1111 2222 2222 2233 #
  # 0123 4567 8901 2345 6789 0123 4567 8901 #
  # DDDD DDDD DDDD DDDD ---- ---- ---- ---- #
  # ---- ---- ---- ---- TTTT T--- ---- ---- #
  # ---- ---- ---- ---- ---- -BBB B--- ---- #
  # ---- ---- ---- ---- ---- ---- -PPP P--- #
  # ---- ---- ---- ---- ---- ---- ---- -R-- #
  # ======================================= #

  TAP_SHIFT = 11
  ADC_A_BITSLIP = 0x080
  ADC_B_BITSLIP = 0x100
  ADC_C_BITSLIP = 0x200
  ADC_D_BITSLIP = 0x400
  ADC_A_PHASE = 0x08
  ADC_B_PHASE = 0x10
  ADC_C_PHASE = 0x20
  ADC_D_PHASE = 0x40
  PHASE_MASK  =  ADC_A_PHASE | ADC_B_PHASE | ADC_C_PHASE |ADC_D_PHASE

  def bitslip(*chans)
    # Preserve "load phase set" bits
    val = adc16_controller[1] & PHASE_MASK
    chans.each do |c|
      val |= case c
            when 0, :a; ADC_A_BITSLIP
            when 1, :b; ADC_B_BITSLIP
            when 2, :c; ADC_C_BITSLIP
            when 3, :d; ADC_D_BITSLIP
            end
    end
    adc16_controller[1] = 0
    adc16_controller[1] = val
    adc16_controller[1] = 0
    self
  end

  def toggle_phase(chip)
    # Clear all but "load phase set" bits
    val = adc16_controller[1] & PHASE_MASK
    adc16_controller[1] = val
    # Toggle chip specific phase bits
    case chip
    when :a, 0; val ^= ADC_A_PHASE
    when :b, 1; val ^= ADC_B_PHASE
    when :c, 2; val ^= ADC_C_PHASE
    when :d, 3; val ^= ADC_D_PHASE
    else raise "Invalid chip: #{chip}"
    end
    # Write new value
    adc16_controller[1] = val
    self
  end

  def delay_tap(chip, tap, chans=0b1111)
    # Clear all but "load phase set" bits
    val = adc16_controller[1] & PHASE_MASK
    adc16_controller[1] = val
    # Set tap bits
    val |= (tap&0x1f) << TAP_SHIFT
    # Set chip specific reset bits for the four channels
    case chip
    when :a, 0; val |= (chans&0xf) << 16
    when :b, 1; val |= (chans&0xf) << 20
    when :c, 2; val |= (chans&0xf) << 24
    when :d, 3; val |= (chans&0xf) << 28
    else raise "Invalid chip: #{chip}"
    end
    # Write value
    adc16_controller[1] = val
    # Clear all but "load phase set" bits
    adc16_controller[1] = val & PHASE_MASK
    sleep 0.1
    self
  end

end # class ADC16

# Class for communicating with snap and trig blocks of adc16_test model.
class ADC16Test < ADC16

  # For each channel given in +chans+ (one or more of :a, :b, :c, :d), a 64K
  # NArray is returned.
  def snap(*chans)
    len = (Fixnum === chans[-1]) ? chans.pop : 1<<16
    self.trig = 0
    chans.each do |chan|
      # snap_x_ctrl bit 0: 0-to-1 = enable
      # snap_x_ctrl bit 1: trigger (0=external, 1=immediate)
      # snap_x_ctrl bit 2: write enable (0=external, 1=always)
      # snap_x_ctrl bit 3: cirular capture (0=one-shot, 1=circular)
      #
      # Due to tcpborphserver3 bug, writes to the control registers must be
      # done using the KATCP ?wordwrite command.  See the email thread at
      # http://www.mail-archive.com/casper@lists.berkeley.edu/msg03457.html
      request(:wordwrite, "snap_#{chan}_ctrl", 0, 0b0000);
      request(:wordwrite, "snap_#{chan}_ctrl", 0, 0b0101);
    end
    self.trig = 1
    sleep 0.01
    self.trig = 0
    chans.each do |chan|
      request(:wordwrite, "snap_#{chan}_ctrl", 0, 0b0000);
    end
    out = chans.map do |chan|
      send("snap_#{chan}_bram")[0,len]
    end
    chans.length == 1 ? out[0] : out
  end

  def walk_taps(chip)
    (0..31).map do |tap|
      delay_tap(chip, tap)
      snap(chip, 1)
    end
  end

end # class ADC16Test
