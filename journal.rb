#!/usr/bin/ruby -w

require "optparse"
require "rexml/document"


class CJournalEntry
  attr_reader :type
  attr_reader :image, :initrd, :cmd
  attr_reader :image_sectors, :initrd_sectors, :cmd_sectors
  attr_reader :image_start, :initrd_start, :cmd_start
  attr_reader :use_initrd
  
  def initialize(ltype, image_name, use_initrd, initrd_name, cmdline)
    @type       = ltype
    @image      = image_name
    @initrd     = initrd_name
    @cmd        = cmdline
    @use_initrd = use_initrd
    
    if(!self.files_present?)
      raise ArgumentError
    end
  end
  
  def files_present?
    if !File.exist?(@image) then
      puts "The file [#{ @image }] does not exist."
      return false
    end
    
    if @use_initrd && !File.exist?(@initrd) then
      puts "The file [#{ @initrd }] does not exist."
      return false
    end
    
    return true
  end
  
  def calculate_sectors(entry_start)
    @image_start = entry_start
    image_bsize = File.stat(@image).size
    @image_sectors = (image_bsize / 512.0).ceil
    
    @initrd_start = @image_start + @image_sectors
    if @use_initrd then
      initrd_bsize = File.stat(@initrd).size
      @initrd_sectors = (initrd_bsize / 512.0).ceil
    else
      @initrd_sectors = 0
    end
    
    @cmd_sectors = 1
    @cmd_start   = @initrd_start + @initrd_sectors
    
  end
  
  def to_s
    "type:#{@type} | #{@image}:start=#{@image_start},len=#{@image_sectors} | #{ @initrd }:start=#{@initrd_start},len=#{@initrd_sectors} | #{@cmd}:start=#{@cmd_start},len=#{@cmd_sectors}"
  end
end

def write_bytes(buf, src, index, byte_cnt)
  
  while byte_cnt > 0 do
    buf[index] = (src & 0xFF)
    src >>= 8
    
    index += 1
    byte_cnt -= 1
  end
  
  return index
end

def run_from_shell(cmd)
  
  puts "Running \"#{ cmd }\""
  rc = system("#{cmd} 2>/dev/null")
  if(rc != true)
    puts "shell command error"
    raise
  end
end

def update_mbr(part_num, device_name)
  
  mbr_data = Array.new(512, 0x00)
  
  run_from_shell("dd if=#{ device_name } of=mbr.bin bs=512 count=1")
  
  File.open("mbr.bin","rb") do |f|
    for i in 0..0x1FF
      mbr_data[i] = f.getc
    end
  end
  
  # Partition table
  for i in 0..3
    if(part_num == i)
      puts "Reconfiguring partition entry #{ i } ..."
      
      offset = 0x1BE + i * 16
      
      mbr_data[offset+0] = 0x00    # Not bootable
     
      # Absolute start CHS address (not used)
      mbr_data[offset+1] = 0x00    # Head
      mbr_data[offset+2] = 0x00    # Sector
      mbr_data[offset+3] = 0x00    # Cylinder
      
      # Partition type
      mbr_data[offset+4] =  0xE8   # New MBFS partition type
      
      # Absolute end CHS address (not used)
      mbr_data[offset+5] = 0x00    # Head
      mbr_data[offset+6] = 0x00    # Sector
      mbr_data[offset+7] = 0x00    # Cylinder
     
      # Capture the journal LBA
      journal_start  = mbr_data[offset+8] |
                       mbr_data[offset+9]<<8 |
                       mbr_data[offset+10]<<16 |
                       mbr_data[offset+11]<<24
      mbfs_size      =  mbr_data[offset+12] |
                       mbr_data[offset+13]<<8 |
                       mbr_data[offset+14]<<16 |
                       mbr_data[offset+15]<<24
    else
      puts "Skipping partition entry #{ i } ..."
    end
  end
  
  # MBR signature
  mbr_data[510] = 0x55
  mbr_data[511] = 0xAA
  
  File.open("mbr.tmp","w+") do |f|
     mbr_data.each { |x| f.putc(x) }
  end

  puts "Replacing MBR ..."
  run_from_shell("dd if=mbr.tmp of=#{ device_name } bs=512 count=1")
  
  return journal_start, mbfs_size
end

def parse_cmdline()
  
  options = {}
  optparse = OptionParser.new do |opts|
    opts.banner = "Creates MBFS partition with journal table on device"
    opts.on('-c', '--config FILE', 'XML configuration file') do |f|
       options['config'] = f
    end
    opts.on('-d', '--device DEVICE', 'Device file') do |f|
       options['device'] = f
    end
  end

  optparse.parse!

  file_name   = options['config']
  device_name = options['device']

  if(file_name.nil? || !File.exist?(file_name))
    puts "Invalid XML file"
    puts optparse
    exit(2)
  end

  if(device_name.nil? || !File.exist?(device_name))
    puts "Invalid device file"
    puts optparse
    exit(2)
  end

  if(device_name.index('/dev/sda') != nil)
    printf "** You've selected a root device /DEV/SDA. Are you sure (Y/N)?"
    
    answer = STDIN.gets
    if((answer.upcase).index('Y') != 0)
      puts "** Aborted by user"
      exit(1)
    end
  end

  return file_name, device_name
end

def load_xml(xml_file)
  
  part_num = 0
  File.open(xml_file, "r") {|f| @xmldoc = REXML::Document.new(f)}

  @xmldoc.each_element("journal/partition") do |element|
    part_num = Integer(element.text)
    if(part_num < 0 || part_num > 3)
      puts "Invalid partition number #{ part_num } (allows 0-3)."
      raise ArgumentError
    else
      break # Only extract the first <partition> block
    end
  end
  
  @xmldoc.each_element("journal/entry") do |element|
    
    tname = element.get_text('name').to_s
    index = Integer(element.get_text('index').value)
    kernel_img = element.get_text('kernel_img').to_s
    initrd     = element.get_text('initrd').to_s
    initrd_img = element.get_text('initrd_img').to_s
    kernel_args= element.get_text('kernel_args').to_s
    
    entry_type = @IMAGE_TYPES[tname]
    
    if(initrd.match(/(true|yes|1)$/i) != nil)
      use_initrd = true
    else
      use_initrd = false
    end
    
    puts "Processing \"#{ tname }\" (index: #{ index }) ..."
    @entry_list[index] = CJournalEntry.new(entry_type,
                                           kernel_img,
                                           use_initrd,
                                           initrd_img,
                                           kernel_args)
    
  end

  return part_num
end

def update_mbfs(journal_start, entries, device_name)
  
  journal_table = Array.new(512, 0x00)

  # Fill out the journal table entries 
# sector_index = journal_start + 1  # Use absolute offset
  sector_index = 1                  # Use relative offset
  padding = 0x00
  bindex = 0

  entries.each do |entry|
    
    # Calculate the number sectors for images and sector LBAs
    entry.calculate_sectors(sector_index)
    
    puts entry.to_s

    journal_entry = [[entry.type, 2],
                     [entry.image_start, 4],
                     [entry.image_sectors, 4],
                     [entry.initrd_start, 4],
                     [entry.initrd_sectors, 4],
                     [entry.cmd_start, 4],
                     [entry.cmd_sectors, 4],
                     [padding, 6]]

    journal_entry.each do |field, size|
      bindex = write_bytes(journal_table, field, bindex, size)
    end

    # Advance for the next journal entry
    sector_index = entry.cmd_start + entry.cmd_sectors
    
    # Write to device file
    run_from_shell("dd if=#{ entry.image } of=#{ device_name } bs=512 count=#{ entry.image_sectors } seek=#{ entry.image_start+journal_start }")
    
    if entry.use_initrd then
      run_from_shell("dd if=#{ entry.initrd } of=#{ device_name } bs=512 count=#{ entry.initrd_sectors } seek=#{ entry.initrd_start+journal_start }")
    end
    
    File.open("kernel_cmd","w+") do |f|
      f.printf("\$kernel_args=#{entry.cmd}\0")
    end
    
    run_from_shell("dd if=kernel_cmd of=#{ device_name } bs=512 count=#{ entry.cmd_sectors } seek=#{ entry.cmd_start+journal_start }")
    run_from_shell("rm -f kernel_cmd")
  end
  
  # number of journal table entries field.
  journal_table[507] = entries.size
  
  # MBFS signature
  journal_table[509] = 'G'   # 0x47
  journal_table[510] = 'E'   # 0x45
  journal_table[511] = 'S'   # 0x53
  
  journal_file = File.open("seg_table.bin","w+")
  journal_table.each { |x| journal_file.putc(x) }
  journal_file.close()
  
  puts "Writing the journal table ..."
  run_from_shell("dd if=seg_table.bin of=#{ device_name } bs=512 count=1 seek=#{journal_start}")
  
end

#
# MAIN
#
@IMAGE_TYPES = {
  "active"      => 0xFFFF,
  "backup"      => 0xFFFE,
  "charging"    => 0xFFFD,
  "fw_update"   => 0xFFFC,
  "fw_recovery" => 0xFFFB
}
@entry_list  = Array.new()

if(Process.euid != 0) then
  puts "** Need to be root"
  exit(1)
end

begin
  config_xml, device = parse_cmdline()
  
  part_num = load_xml(config_xml)
  
  journal_lba, mbfs_size = update_mbr(part_num, device)
  
  puts "Installing journal table to #{device} partition ##{part_num} (LBA=#{journal_lba},size=#{mbfs_size})"

  if (journal_lba < 1 || mbfs_size < 1)
    puts "Invalid partition offset or size"
    puts "Please create an empty partition first before installing MBFS"
    raise ArgumentError
  end
  update_mbfs(journal_lba, @entry_list, device)
  
  puts "Done!"
  
rescue OptionParser::MissingArgument
  puts "Missing arguments."
  exit(2)
rescue ArgumentError
  puts "Bad configurations."
  exit(3)
rescue RuntimeError => e
  puts e.message
  puts "ERROR: Sorry. This tool failed to work. Please seek support."
  exit(1)
end

