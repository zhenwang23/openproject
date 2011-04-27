class Report::Result
  include Report::QueryUtils

  class Base
    attr_accessor :parent, :type, :important_fields
    attr_accessor :key
    attr_reader :value
    alias values value
    include Enumerable
    include Report::QueryUtils

    def initialize(value)
      @important_fields ||= []
      @type = :direct
      @value = value
    end

    def recursive_each_with_level(level = 0, depth_first = true, &block)
      block.call(level, self)
    end

    def recursive_each
      recursive_each_with_level { |level, result| yield result }
    end

    def to_hash
      fields.dup
    end

    def [](key)
      fields[key]
    end

    def grouped_by(fields, type, important_fields = [])
      @grouped_by ||= {}
      list = begin
        @grouped_by[fields] ||= begin
          # sub results, have fields
          # i.e. grouping by foo, bar
          data = group_by do |entry|
            # index for group is a hash
            # i.e. { :foo => 10, :bar => 20 } <= this is just the KEY!!!!
            fields.inject({}) do |hash, key|
              val = entry.fields[key]
              if key =~ /^number_of.*/
                if val.to_i >= 10
                  val = "10+"
                end
              end
              hash.merge key => val # entry.fields[key]
            end
          end
          if data.keys.size > 0
            num = data.keys[0].keys.find { |key| key =~ /^number_of.*/ }
            data.keys.find_all { |key| key[num].to_i >= 10 }.each do |key|
              unique_results = []
              data[key].each do |result|
                pkey = result.fields.except num, "count"
                if (tuple = unique_results.find { |t| t[0] == pkey })
                  ures = tuple[1]
                  ures.fields["count"] = (ures.fields["count"].to_i + result.fields["count"].to_i).to_s
                else
                  ures = result
                  ures.fields[num] = "10+"
                  unique_results << [pkey, ures]
                end
              end
              data[key] = unique_results.collect { |tuple| tuple[1] }
            end
          end
          # map group back to array, all fields with same key get grouped into one list
          data.keys.map { |f| engine::Result.new data[f], f, type, important_fields }
        end
      end
      # create a single result from that list
      engine::Result.new list, {}, type, important_fields
    end

    def inspect
      "<##{self.class}: @fields=#{fields.inspect} @type=#{type.inspect} " \
      "@size=#{size} @count=#{count} @units=#{units}>"
    end

    def row?
      type == :row
    end

    def column?
      type == :column
    end

    def direct?
      type == :direct
    end

    def each_row
    end

    def final?(type)
      type? type and (direct? or size == 0 or first.type != type)
    end

    def type?(type)
      self.type == type
    end

    def depth_of(type)
      if type? type or (type == :column and direct?) then 1
      else 0
      end
    end

    def final_number(type)
      return 1 if final? type
      return 0 if direct?
      @final_number ||= {}
      @final_number[type] ||= sum { |v| v.final_number type }
    end

    def final_row?
      final? :row
    end

    def final_column?
      final? :column
    end

    def render(keys = important_fields)
      fields.map { |k,v| yield(k,v) if keys.include? k }.join
    end

    def set_key(index = [])
      self.key = index.map { |k| map_field(k, fields[k]) }
    end

  end

  class DirectResult < Base
    alias fields values

    def has_children?
      false
    end

    def count
      self["count"].to_i
    end

    def units
      self["units"].to_d
    end

    ##
    # @return [Integer] Number of child results
    def size
      0
    end

    def each
      return enum_for(__method__) unless block_given?
      yield self
    end

    def each_direct_result(cached = false)
      return enum_for(__method__) unless block_given?
      yield self
    end

    def sort!(force = false)
      force
    end
  end

  class WrappedResult < Base
    include Enumerable

    def set_key(index = [])
      values.each { |v| v.set_key index }
      super
    end

    def sort!(force = false)
      return false if @sorted and not force
      values.sort! { |a,b| a.key <=> b.key }
      values.each { |e| e.sort! force }
      @sorted = true
    end

    def depth_of(type)
      super + first.depth_of(type)
    end

    def has_children?
      true
    end

    def count
      sum_for :count
    end

    def units
      sum_for :units
    end

    def sum_for(field)
      @sum_for ||= {}
      @sum_for[field] ||= sum { |v| v.send(field) || 0 }
    end

    def recursive_each_with_level(level = 0, depth_first = true, &block)
      if depth_first
        super
        each { |c| c.recursive_each_with_level(level + 1, depth_first, &block) }
      else #width-first
        to_evaluate = [self]
        lvl = level
        while !to_evaluate.empty? do
          # evaluate all stored results and find the results we need to evaluate soon
          to_evaluate_soon = []
          to_evaluate.each do |r|
            block.call(lvl,r)
            to_evaluate_soon.concat r.values if r.size > 0
          end
          # take new results to evaluate
          lvl = lvl +1
          to_evaluate = to_evaluate_soon
        end
      end

      def each_row
        return enum_for(:each_row) unless block_given?
        if final_row? then yield self
        else each { |c| c.each_row(&Proc.new) }
        end
      end
    end

    def to_a
      values
    end

    def each(&block)
      values.each(&block)
    end

    def each_direct_result(cached = true)
      return enum_for(__method__) unless block_given?
      if @direct_results
        @direct_results.each { |r| yield(r) }
      else
        values.each do |value|
          value.each_direct_result(false) do |result|
            (@direct_results ||= []) << result if cached
            yield result
          end
        end
      end
    end

    def fields
      @fields ||= {}.with_indifferent_access
    end

    ##
    # @return [Integer] Number of child results
    def size
      values.size
    end
  end

  def self.new(value, fields = {}, type = nil, important_fields = [])
    result = begin
      case value
      when Array then engine::Result::WrappedResult.new value.map { |e| new e, {}, nil, important_fields }
      when Hash  then engine::Result::DirectResult.new value.with_indifferent_access
      when Base  then value
      else raise ArgumentError, "Cannot create Result from #{value.inspect}"
      end
    end
    result.fields.merge! fields
    result.type = type if type
    result.important_fields = important_fields unless result == value
    result
  end
end
