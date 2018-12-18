# ofsted-analysis

*** The Script ***
Scrapes and analyses Ofsted reports
Adapted from https://github.com/jdkram/ofsted-report-scraper

Script isn't perfect, but its intent is to...
1. Identify the schools that have been inspected in the specified date window and the link to their report page
2. Scrape the identified reports from those pages
3. Convert those reports from PDFs to text files
4. Search the text files for the specified search terms

A CSV file is written throughout the process such that, if it's interrupted, the script can be run again from the start and pick up where it stopped.

Code is partially annotated but needs more!


*** The Excel sheet ***
Having created the CSV file with the raw data, this is dumped into the back of an Excel sheet with named ranges.

The sheet is intended to pull out specific interactions: e.g., secondary schools with a full inspection rated good

Any comments or feedback to m.hickman@wellcome.ac.uk
