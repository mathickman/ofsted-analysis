require 'nokogiri' # parse HTML
require 'csv'
require 'httparty' # download pages
require 'open-uri'
require 'open_uri_redirections' # Need this too, as redirect to report PDFs
require 'pdf-reader' # fastest PDF gem I've tried
require 'enumerator'
require 'ruby-progressbar'

##
# schools have
#	urn 				int
#	name				str
#	type				str
#	rating				str
#	url					str
#	address				str
#	latest_report		date
#	report_type			str
#	report_url			str
#	report_downloaded	str (name of report)
#	report_converted	str (name of converted report)
##

class OfstedReports
	include HTTParty
	base_uri "https://reports.ofsted.gov.uk"
	CHUNK = 250 #number of schools returned per each page of search - go large?!
	@@keyword_searches = []
	@@search_name = ""
	@@download_path = []
	@@schools_csv = ""

	@@schools = []
	def self.schools
		@@aschools
	end
	def schools
		self.class.schools
	end
	
	def initialize(s_name, download_to, school_type, search_start, search_end, keywords=nil)
		#set up variables
		@@search_name = s_name
		@@download_path = download_to
		if @@download_path[-1] != "/"
			@@download_path = @@download_path + "/"
		end
		@@schools_csv = @@download_path + @@search_name + ".csv"
		puts File.absolute_path(File.dirname(@@schools_csv))
		unless keywords.nil?
			keywords.each do |word|
				@@keyword_searches << Regexp.new(word)
			end
		end
	
		#initialise a search
    	@options = {
    		query: {
    			q: "",
    			location: "",
    			radius: 3,
    			:level_2_types=>{0=>school_type},
    			#:level_3_types=>{0=>9,1=>10},
    			latest_report_date_start: search_start,
    			latest_report_date_end: search_end,
    			:status=>{0=>1},
    			level_1_types: 1,
    			start: 0,
    			rows: CHUNK
    		}
    	}
    	r = Nokogiri::HTML(self.class.get("/search", @options))
    	schools_count = Integer(r.css('div.search-results__heading strong.results-count')[0].inner_text)
		@page_count = Integer(r.css('span.pagination__numbers').inner_text[/(?<=1 of ).+/])
		puts "\n *** Search ready ok: will scrape #schools_count schools over #@page_count pages"
		
		#check if this is a new search
		if File.exist?(@@schools_csv)
			puts "Updating existing search - retrieving information"
			@@schools = CSV.read(@@schools_csv, {headers: true, return_headers: false, header_converters: :symbol, converters: :all}).map(&:to_h)
		end
		return true
	end
	
	def do_search()
		progressbar = ProgressBar.create(starting_at: 0, total: @page_count, format: "%a %e %c/%C search pages scraped: |%B|")
		(1..@page_count).each do |page| #should be 1..@page_count #LOAD PAGE TO SCRAPE
			@options[:query][:start] = (page - 1) * CHUNK
			@options[:query][:rows] = CHUNK
			doc = Nokogiri::HTML(self.class.get("/search", @options))
			results_list = doc.css('ul.results-list li.search-result')
			schools_page = []
			results_list.each do |result| #interrogate page
				sch_details = result.css('ul.search-result__provider-info li')
				result_details = {
					urn: sch_details.css('li')[0].inner_text[/(?<=: ).+/],
					name: result.css('h3.search-result__title').inner_text,
					type: sch_details.css('li')[1].inner_text[/(?<=: ).+/],
					rating: result.css('div.search-result__provider-rating p strong').inner_text,
					url: result.css('h3.search-result__title a').attribute('href').to_s,
					address: result.css('address.search-result__address').inner_text,
					latest_report: sch_details.css('li')[2].inner_text[/(?<=: ).+/],
					report_downloaded: "",
					report_converted: ""
				}
				unless (i = @@schools.index(@@schools.find { |s| String(s[:urn]) == String(result_details[:urn]) }))
					@@schools << result_details
				else
					@@schools[i] = result_details
				end
			end
			progressbar.increment
			sleep rand(0.1..0.6)
		end
		write_CSV(@@schools)
		puts "\n *** Search complete\n\n"
		return true
	end
	
	def get_all_school_report_details()
		progressbar = ProgressBar.create(starting_at: 0, total: @@schools.length, format: "%a %e %c/%C schools processed: |%B|")
		i = 0
		@@schools.each do |school|
			unless (school.has_key? :report_url)
				doc = Nokogiri::HTML(self.class.get(school[:url])) #get the school's page
				reports = doc.search('a.publication-link')
				reports.each do |report|
					if (report.parent.css('time').inner_text == school[:latest_report]) #if this is the latest report, get it
						@@schools[i][:report_url] = report.attribute('href').to_s
						@@schools[i][:report_type] = report.parent.css('span.nonvisual').inner_text[/(.+)(?=,)/]
					end
				end
			end
			progressbar.increment
			i = i + 1
		end
		write_CSV(@@schools)
		puts "\n *** All school report details retrieved\n\n"
		return true
	end
	
	def download_report_pdf(report_url)
		if (report_url.nil?) then return "No report" end
		file = File.basename(report_url)
		path = @@download_path + file
		if !File.exist?(path)
			File.open(path, "wb") do |file|
				tries = 0
				begin
					open(report_url, "rb", :allow_redirections => :all) do |pdf| # Allow for silly HTTP
						file.write(pdf.read)
					end
				rescue OpenURI::HTTPError => e
					if tries < 5
						sleep tries * 5.0 + rand * 5.0
						puts " *** Connection failed (#{e.message}) on #{report_url}, retrying..."
						puts e
						tries = tries + 1
						retry 
					else
						next
					end
				end
			end
			return file
		else
			return file
		end
	end
		
	def download_all_report_pdfs()
		files = Dir.entries(@@download_path)
		reports = @@schools.select {|s| !files.include?(String(s[:report_downloaded]))}
		progressbar = ProgressBar.create(starting_at: (@@schools.length - reports.length), total: @@schools.length, format: "%a  %e %c/%C reports downloaded: |%B|")
		reports.each do |school|
			i = @@schools.index(@@schools.find {|s| s[:urn] == school[:urn]})
			@@schools[i][:report_downloaded] = download_report_pdf(school[:report_url])
			write_CSV(@@schools)
			progressbar.increment
		end
		puts "\n *** All reports downloaded\n\n"
		return true
	end
	
	def convert_pdf(pdf, output_file=nil)
		if File.exist?(pdf)
			output_file ||= pdf + '.txt'
			unless File.exist?(output_file)
				text = ""
				parsed_file = PDF::Reader.new(pdf)
				parsed_file.pages.each {|page| text.concat(page.text)}
				File.write(output_file, text)
			end
			return File.basename(output_file)
		else
			return "No PDF to convert"
		end
	end

	def convert_pdfs(folder = @@download_path)
		files = Dir.entries(@@download_path)
		pdfs = @@schools.select {|f| File.exist?(@@download_path + String(f[:report_downloaded])) } #has it been downloaded?
		pdfs = pdfs.select {|f| !files.include?(String(f[:report_converted])) } #has it been converted?
		progressbar = ProgressBar.create(starting_at: (@@schools.count - pdfs.count), total: @@schools.count, format: "%a %e %c/%C PDFs converted (%P%)")
		pdfs.each do |f|
			pdf = @@download_path + String(f[:report_downloaded])
			begin
				f[:report_converted] = String(convert_pdf(pdf))
				progressbar.increment
			rescue PDF::Reader::MalformedPDFError
				f[:report_converted] = "Malformed PDF: #{pdf}"
				progressbar.log "Malformed PDF: #{pdf}"
				next
			end
			write_CSV(@@schools)
		end
		puts "\n *** All PDFs converted ***"
	end
	
	def scan()
		files = Dir.glob(@@download_path + '*.txt')
		to_scan = []
		to_scan = @@schools.select {|s| (File.exist?(@@download_path + String(s[:report_converted])) && !s[:report_converted].nil?) }
		counts = []
		progressbar = ProgressBar.create(starting_at: 0, total: to_scan.count, format: "%a %e %c/%C reports scanned (%P%)")
		to_scan.each do |school|
			fs = @@download_path + String(school[:report_converted])
			unless File.directory?(fs)
				text = File.open(fs, "r").read.gsub('\n','') # clear newlines introduced by PDF
				search_results = Hash.new
				@@keyword_searches.each do |search|
					col_name = search.source + ("_mention")
					search_results[col_name] = 0
					text.scan(/#{search}/i) {search_results[col_name] += 1}
				end
				corrupt_pdf = text.include?('?????????')
				puts file if corrupt_pdf 
				counts.concat(
					[
						{
							urn: school[:urn],
							filename: school[:report_converted],
							corrupt_pdf: corrupt_pdf
						}.merge(search_results)
					]
				)
			else
				progressbar.log "School URN #{school[:urn]}, report #{fs} has no report text to scan"
			end
			progressbar.increment
		end
		puts "Scanned #{to_scan.count} reports."
		return counts
	end
	
	def write_CSV(rows, name_modifier=nil)
		headers = rows[0].keys
		csv_content = CSV.generate do |csv|
			csv << headers
			rows.each { |r| csv << r.values }
		end

		if name_modifier.nil?
			filename = @@schools_csv
		else
			filename = @@schools_csv[0..-5] + name_modifier + ".csv"
		end
		File.write(filename, csv_content)
	end
end

PRIMARY = 1
SECONDARY = 2

search_words = [
	"scien",
	"math",
	"engineering",
	"engineer",
	"music",
	"geography",
	"modern foregin languages|MFL",
	"art",
	"computing|computer science",
	"investigation|experiment",
	"CPD|professional development",
	"neuroscience",
	"cogniti",
	"humanities",
	"rigour",
	"field work|field trip|fieldwork",
	"mindset",
	"mindfulness",
	"learning style",
	"physics",
	"chemistry",
	"biology",
	"practical",
	"English"
]

#primary_reports = OfstedReports.new("2009-19 Primary", "./output", PRIMARY, "01-09-2009", "25-04-2019", search_words)
#primary_reports.do_search()
#primary_reports.get_all_school_report_details()
#primary_reports.download_all_report_pdfs()
#primary_reports.convert_pdfs()
#primary_reports.write_CSV(primary_reports.scan, "_search_results")

secondary_reports = OfstedReports.new("2009-19 Secondary", "./output", SECONDARY, "01-09-2009", "25-04-2019", search_words)
secondary_reports.do_search()
secondary_reports.get_all_school_report_details()
secondary_reports.download_all_report_pdfs()
secondary_reports.convert_pdfs()
secondary_reports.write_CSV(secondary_reports.scan, "_search_results")