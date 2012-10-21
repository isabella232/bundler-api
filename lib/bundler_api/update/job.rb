require_relative 'payload'

class Job
  attr_reader :payload

  def initialize(db, payload)
    @db      = db
    @payload = payload
    @mutex   = Mutex.new
  end

  def run
    unless gem_exists?(@payload.name, @payload.version)
      spec = download_spec(@payload.name, @payload.version, @payload.platform)
      @mutex.synchronize do
        insert_spec(spec)
      end
    end
  end

  private
  def gem_exists?(name, version)
    dataset = @db[<<-SQL, name, version.version]
    SELECT versions.id
    FROM rubygems, versions
    WHERE rubygems.id = versions.rubygem_id
      AND rubygems.name = ?
      AND versions.number = ?
    SQL

    dataset.count > 0
  end

  def download_spec(name, version, platform)
    puts "Processing: #{name}-#{version.version}"
    full_name = "#{name}-#{version}"
    full_name << "-#{platform}" if platform != 'ruby'
    spec = nil

    Dir.mktmpdir do |dir|
      `cd #{dir} && curl https://rubygems.org/downloads/#{full_name}.gem -s -L -o - | tar vxf - 2>&1 > /dev/null`
      `cd #{dir} && gunzip metadata.gz`
      spec = YAML.load_file("#{dir}/metadata")
    end

    spec
  end

  def insert_spec(spec)
    raise "Failed to load spec" unless spec

    @db.transaction do
      rubygem    = @db[:rubygems].filter(name: spec.name.to_s).select(:id).first
      rubygem_id = nil
      if rubygem
        rubygem_id = rubygem[:id]
      else
        rubygem_id = @db[:rubygems].insert(
          name:       spec.name,
          created_at: Time.now,
          updated_at: Time.now,
          downloads:  0
        )
      end

      version_id = @db[:versions].insert(
        authors:     spec.authors,
        description: spec.description,
        number:      spec.version.version,
        rubygem_id:  rubygem_id,
        updated_at:  Time.now,
        summary:     spec.summary,
        created_at:  Time.now,
        indexed:     true,
        prerelease:  false,
        latest:      true,
        full_name:   spec.full_name,
      )
      spec.dependencies.each do |dep|
        dep_rubygem = @db[:rubygems].filter(name: dep.name).select(:id).first
        if dep_rubygem
          @db[:dependencies].insert(
            requirements: dep.requirement.to_s,
            created_at:   Time.now,
            updated_at:   Time.now,
            rubygem_id:   dep_rubygem[:id],
            version_id:   version_id,
            scope:        dep.type.to_s,
          )
        end
      end
    end
  end
end
