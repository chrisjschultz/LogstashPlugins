# Genjdbc v0.1
# Date 06 February 2015 09:00:00 GMT
# Logstash Generic JDBC Input PlugIn
# Authors: Stuart Tuck & Rob McKeown
#
# This is a community contributed content pack and no explicit support, guarantee or warranties
# are provided by IBM nor the contributor. Feel free to engage the community on the ITOAdev
# forum if you need help!
#
# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "java"
require "rubygems"
require "pstore"

# This Input Plug Is Intended to Read Events from a JDBC url
#
# Like stdin and file inputs, each row returned from the remote system
# is assumed to result in one line of output.
#
class LogStash::Inputs::Genjdbc < LogStash::Inputs::Base
  config_name "genjdbc"
  milestone 1

  default :codec, "plain"

  # Configuration Parameters of the remote instance
  config :jdbcHost, :validate => :string, :required => true
  config :jdbcPort, :validate => :string, :required => true
  config :jdbcDBName, :validate => :string, :required => true
  config :jdbcTargetDB, :validate => :string, :required => true
  config :jdbcDriverPath, :validate  => :string, :required => true
  config :jdbcUser, :validate  => :string, :required => true
  config :jdbcPassword, :validate  => :string, :required => true
  config :jdbcSQLQuery, :validate  => :string, :required => true
  config :jdbcURL, :validate  => :string, :required => false
  config :jdbcTimeField, :validate => :string, :required => false
  config :jdbcTimeBindNumber, :validate => :number, :required => false
  config :jdbcIdField, :validate => :string, :required => false
  config :jdbcIdBindNumber, :validate => :number, :required => false
  config :jdbcPollInterval, :validate => :string, :required => false
  config :jdbcCollectionStartTime, :validate => :string, :required => false
  config :jdbcPStoreFile, :validate => :string, :required => false, :default => "genjdbc.pstore"
  

  # The 'read' timeout in seconds. If a particular connection is idle for
  # more than this timeout period, we will assume it is dead and close it.
  # ToDo: Implement more awareness of connection state.
  # If you never want to timeout, use -1.
  #config :data_timeout, :validate => :number, :default => -1

  def initialize(*args)
    super(*args)
  end # def initialize

  public
  def register
    @logger.info("Starting JDBC input", :address => "#{@jdbcHost}")
  end # def register
  
  public
  def run(queue)
    require 'java'
    require 'date'
    require @jdbcDriverPath

    # Load the Driver Manager Classes required to create/operate sql connection
    java_import java.sql.DriverManager
    java_import java.sql.Connection
    import java.lang.System

    
    # Database Selection
    # ----------------------------------------------------------------------------------------------------------
    if @jdbcTargetDB == "postgresql"
      driver = org.postgresql.Driver.new
      driverurl = "jdbc:postgresql://"+@jdbcHost+":"+@jdbcPort+"/"+@jdbcDBName
      # Spec. jdbc:postgresql://<server>:<5432>/<database_name>
    end
    if @jdbcTargetDB == "oracle"
      driver = Java::oracle.jdbc.driver.OracleDriver.new
      driverurl = 'jdbc:oracle:thin:@'+@jdbcHost+':'+@jdbcPort+':'+@jdbcDBName
      # Spec. jdbc:oracle:thin:@<server>[:<1521>]:<database_name>
    end
    if @jdbcTargetDB == "db2"
      driver = Java::com.ibm.db2.jcc.DB2Driver.new
      driverurl = "jdbc:db2://"+@jdbcHost+":"+@jdbcPort+"/"+@jdbcDBName
      # Spec. jdbc:db2://<server>:<6789>/<db-name>
    end
    if @jdbcTargetDB == "mysql"
      driver = com.mysql.jdbc.Driver.new
      driverurl = "jdbc:mysql://"+@jdbcHost+":"+@jdbcPort+"/"+@jdbcDBName+"?profileSQL=true"
      # Spec. jdbc:mysql://<hostname>[,<failoverhost>][<:3306>]/<dbname>[?<param1>=<value1>][&<param2>=<value2>]
    end
    if @jdbcTargetDB == "derby"
      driver = org.apache.derby.jdbc.ClientDriver.new
      driverurl = "jdbc:mysql://"+@jdbcHost+":"+@jdbcPort+"/"+@jdbcDBName
      # Spec. jdbc:derby://<server>[:<port>]/<databaseName>[;<URL attribute>=<value>]
    end
    if @jdbcTargetDB == "mssql"
      driver = com.microsoft.sqlserver.jdbc.SQLServerDriver.new
      driverurl = "jdbc:sqlserver://"+@jdbcHost+":"+@jdbcPort+";databaseName="+@jdbcDBName
      # Spec. jdbc:sqlserver://<server_name>:1433;databaseName=<db_name>
    end
    
    
    # Check the jdbcURL setting to see if there is an override, and use constructed URL if not.
    if jdbcURL.nil?
        @jdbcURL = driverurl
    end
   
    # Set the connection properties 
    props = java.util.Properties.new
    props.setProperty("user",@jdbcUser)
    props.setProperty("password",@jdbcPassword)

    # Create a new connection to the jdbc URL, using the connection properties
    @logger.info("Creating Connection to JDBC URL", :address => "#{@jdbcURL}")
    conn = driver.connect(@jdbcURL,props)

    # Prepare the store where we'll track most recent timestamp
    store = PStore.new(@jdbcPStoreFile)
    
    # Set a start time
    lastEvent = java.sql.Timestamp.new(System.currentTimeMillis);
    lastId = 0
    store.transaction { 
      lastEvent = store.fetch(:lastEvent, java.sql.Timestamp.new(System.currentTimeMillis)) 
      lastId = store.fetch(:lastId, 0) 
    }
    @logger.info("Got stored data", :lastEvent => "#{lastEvent}", :lastId => "#{lastId}")
    
    # If set, make an override from the config..
    if !@jdbcCollectionStartTime.nil?
      lastEvent = DateTime.parse @jdbcCollectionStartTime
    end

    # Read query from file if so configured
    if @jdbcSQLQuery.start_with? "file:"
      queryFilename = @jdbcSQLQuery
      queryFilename.slice! "file:"
      queryFile = File.open(queryFilename,"rb")
      originalQuery = queryFile.read
      queryFile.close
      originalQuery = originalQuery.gsub("\n"," ")
    else
      originalQuery = @jdbcSQLQuery
    end
    @logger.info("Parsed SQL", :originalQuery => "#{originalQuery}")
    stmt = conn.prepareStatement(originalQuery)
    @logger.info("Statement Prepared")
    
    cal = java.util.Calendar.getInstance();
    cal.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
    # Main Loop
    while true
      
#      # Debug : puts "lastEvent : "+lastEvent.to_s
#      jdbclastEvent = lastEvent.strftime("%Y-%m-%d %H:%M:%S")
#      currentTime = jdbclastEvent
      
#      stmt = conn.create_statement

#      escapedQuery = originalQuery
#
#      if escapedQuery.include? "%{CURRENTID}"
#        @logger.debug( "setting last id")
#        escapedQuery = escapedQuery.gsub("%{CURRENTID}",lastId.to_s)
#        @logger.debug( "setting last id", :query => "#{originalQuery}")
#      end
#
#      # If query explicity refers to CURRENTTIME, then use that directly
#      if escapedQuery.include? "%{CURRENTTIME}"
#        escapedQuery = escapedQuery.gsub("%{CURRENTTIME}",currentTime)
#      else
#
#      # if not, we'll implicity assemble query
#      # Suggest removing this option completely and making it explicity
#      # Escape sql query provided from config file
#        begin
#          if originalQuery.include? " where " then
#            escapedQuery = originalQuery + " and "+@jdbcTimeField+" > '" + jdbclastEvent + "'" + " order by " +@jdbcTimeField
#          else
#            escapedQuery = originalQuery + " where "+@jdbcTimeField+" > '" + jdbclastEvent + "'" +  " order by " +@jdbcTimeField
#          end
#        end
#      end
#
#
#      escapedQuery = escapedQuery.gsub(/\\\"/,"\"")
#
#      @logger.info("Running Query : ", :query => "#{escapedQuery}")
    
      @logger.info("Binding", :num => "#{@jdbcIdBindNumber.to_i}", :lastId => "#{lastId.to_i}")
      @logger.info("Binding", :num => "#{@jdbcTimeBindNumber.to_i}", :lastEvent => "#{lastEvent}")
      stmt.setLong(@jdbcIdBindNumber.to_i, lastId.to_i)
      stmt.setTimestamp(@jdbcTimeBindNumber, lastEvent, cal)
      @logger.info("Variables bound")
      
      # Execute Query Statement
      rs = stmt.executeQuery()

      rsmd = rs.getMetaData();
      columnCount = rsmd.getColumnCount()

      rowcount = 0

      while (rs.next) do
        rowcount = rowcount + 1
        event = LogStash::Event.new()
        event["jdbchost"] = @jdbcHost

        for i in 1..columnCount
          columnName = rsmd.getColumnName(i)
          value = rs.getString(columnName)
          
          # Debug (find out columntype for each object)
          #columnType = rsmd.getColumnTypeName(i)          
          #puts "Column Type is : "+(columnType)
           
          if value.nil?
            #substitute "" for <nil> returned by DB
            value = ""
          end
          event[columnName.downcase] = value  

          # Check the column to set the latest time field
          if columnName == @jdbcTimeField
            # debug: puts "Time Column is : "+columnName
            
            eventTime = rs.getTimestamp(columnName, cal)
            @logger.info("Using the following event time: ", :eventDate => "#{eventTime}")
            event.timestamp= Time.at(eventTime.getTime()/1000).utc

            if eventTime > lastEvent
              lastEvent = eventTime
              store.transaction do
                store[:lastEvent] = lastEvent
              end
            end
          end
          
          if columnName == @jdbcIdField
            # debug: puts "Id Column is : "+columnName
            if value.to_i > lastId.to_i
              lastId = value
              @logger.info("Storing last read value", :last_id => lastId)
              store.transaction do
                store[:lastId] = lastId
              end
            end
          end

          
        end # for

        # Todo, check how many rows collected .. rowcount++
        decorate(event)
        queue << event

      end
      @logger.info("Found rows from the Database:", :rowcount=> rowcount)
      rs.close
      
      
      # Now need to sleep for interval
      @logger.info("Sleeping for ", :interval_seconds => "#{@jdbcPollInterval.to_i}")
      sleep(@jdbcPollInterval.to_i)
      # zzzzzZZZZ
      
    end # While true (end loop)
    
  rescue LogStash::ShutdownSignal
    # nothing to do
  ensure
    # Close the JDBC connection
    @logger.info("Closing Connection to JDBC URL", :address => "#{@jdbcURL}")
    stmt.close
    conn.close() rescue nil
  end # def run
  
  def teardown
      @interrupted = true
  end # def teardown
  
end # class LogStash::Inputs::Genjdbc
