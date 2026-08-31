namespace :openapi do
  desc "Verify the committed doc/openapi.yaml matches a fresh regeneration, ignoring example values"
  task verify: :environment do
    require "yaml"

    # rspec-openapi's `example:`/`examples:` blocks are captured from live
    # request specs, so they embed randomized factory data, auto-increment
    # ids, live timestamps, and bearer tokens - none of which repeat
    # between two runs of the exact same code. A byte-for-byte diff would
    # therefore flag "stale docs" on every single run, whether or not
    # anything meaningful actually changed. Stripping example values
    # before comparing leaves exactly the part that's supposed to be
    # stable across runs - paths, schemas, types, required fields,
    # response codes - and that's what "up to date" should mean here.
    strip_examples = lambda do |node|
      case node
      when Hash
        node.each_with_object({}) do |(key, value), result|
          next if key == "example" || key == "examples"

          result[key] = strip_examples.call(value)
        end
      when Array
        node.map { |value| strip_examples.call(value) }
      else
        node
      end
    end

    path = Rails.root.join("doc/openapi.yaml")
    committed_yaml = `git show HEAD:doc/openapi.yaml 2>/dev/null`

    if committed_yaml.empty?
      warn "doc/openapi.yaml isn't committed yet - run OPENAPI=1 bundle exec rspec and commit it."
      exit 1
    end

    committed = strip_examples.call(YAML.safe_load(committed_yaml))
    current = strip_examples.call(YAML.load_file(path))

    if committed == current
      puts "doc/openapi.yaml is up to date."
    else
      warn "doc/openapi.yaml is out of date (ignoring example values, which vary run to run)."
      warn "Run 'OPENAPI=1 bundle exec rspec' locally and commit the result."
      exit 1
    end
  end
end
