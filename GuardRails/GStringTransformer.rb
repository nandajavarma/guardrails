require 'ruby_parser'
require 'GSexp'
require 'pp'
require 'action_view'
require 'ruby2ruby'

#include ActionView
#include Helpers
#include TextHelper

class GTransformer
  # There are a bunch of individual transformations that need to happen before we can do taint tracking
  def default_transformations(asts)

    # Application controller file needs some additions
    app_control = asts[:controller]['application_controller.rb']
    app_control = asts[:controller]['application.rb'] if app_control.nil?
    app_control.insert_into_class! @parser.parse("include TaintSystem; include TaintTypes; include ExtraString"),true
    app_control.insert_into_class! @parser.parse('before_filter :taint_setup'),true
    app_control.insert_into_class! @parser.parse('
	def taint_setup
		if params != nil
		   params.each_pair do |key, val|
			if !in_set?(["authenticity_token","controller","action"],key)
				if val.class == String
					params[key] = val.mark_default_tainted
				elsif Hash === val
					val.each_pair do |key2,val2|
			     		    if val2.class == String
				       	 	params[key][key2] = val2.mark_default_tainted
			     	 	    end
				        end
		      	        end
		        end
	           end
		end
	 end')

    # All models need to include TaintSystem
    for ast in asts[:model].values do
      ast.insert_into_class! @parser.parse("include TaintSystem"), true
    end
  end

  # Some functions like interpolation do not work with our tainting system.
  # They must be converted into equivalent functions that do work with the system.
  def disallow_features(ast)
    interp_to_concat ast
  end

  # This function is really bad, but works for now.
  def process_fields_and_transform_schema(ast)
    tables_to_fields = {}

    for iter_block in ast.deep_find_all(
      lambda { |sexp| sexp[0] == :iter and sexp[1].is_a? Sexp and sexp[1][0] == :call and sexp[1][2] == :create_table} ) do
      # Bad practice. Weird syntax causes crashes
      call_block 		= iter_block[1]
      table_name 		= call_block[3][1][1]
      column_blocks 	= iter_block[3]

      tables_to_fields[table_name] = []
      new_columns = []

      for column_block in column_blocks do
        next unless column_block.is_a? Sexp
        next unless column_block[0] == :call
        next unless column_block[2] == :string

        field_name 		 = column_block[3][1][1]
        new_field_name	 = Sexp.from_array [:str, "#{field_name}_taint"]
        new_arglist		 = Sexp.from_array [:arglist, new_field_name]

        new_column = column_block.deep_copy
        new_column[3] = new_arglist
        new_columns.push new_column

        tables_to_fields[table_name].push field_name
      end unless ast.nil?

      # Add in new columns after the looping to prevent infinite loop
      for new_column in new_columns do
        column_blocks.push new_column
      end
    end
    return tables_to_fields
  end

  def convert(tables_to_fields)
    models_to_fields = {}
    for table in tables_to_fields.keys do
      modelname = "#{table[0..-2].downcase}.rb"
      models_to_fields[modelname] = tables_to_fields[table]
    end
    return models_to_fields
  end

  # We need to modify the models to handle getting the taint information
  # from the database and combining it with its matching string.
  def transform_model(ast, field_list)
    if !field_list.nil?
      for field in field_list do

        # Need to serialize the taint data so it can be stored in the db
        ast.insert_class_stmt @parser.parse(
        "serialize :#{field}_taint"), true

        # Getter needs to be modified to get the taint data
        # Setter needs to be modified to store the taint data
        # Not sure if this plays nicely with the access policy aliases

        ast.insert_class_stmt @parser.parse(
        "alias str_raw_#{field} #{field}")
        ast.insert_class_stmt @parser.parse(
        "def #{field}
  	   result = str_raw_#{field}
	   result.taint = #{field}_taint unless result.nil? or !result.taint.nil?
	   return result
	end")

        ast.insert_class_stmt @parser.parse(
        "alias str_raw_#{field}= #{field}=")
        ast.insert_class_stmt @parser.parse(
           "def #{field}=(val)
		self.send('str_raw_#{field}=', val)
                if val.is_a?(String)
   		   self.#{field}_taint = val.taint
                end
   	   end")
      end
    end
  end

  def create_taint_migration field_list
    ans_up="  def self.up\n"
    ans_down="  def self.down\n"
    for k in field_list
      k[0]=k[0][0...-3].pluralize
      for x in k[1]
        ans_up+="    add_column :"+k[0]+", :"+x+"_taint, :string\n"
        ans_down+="    remove_column :"+k[0]+", :"+x+"_taint\n"
      end
    end
    return "class AddTaintFields < ActiveRecord::Migration\n"+ans_up+"  end\n\n"+ans_down+"  end\nend\n"
  end

  def taint_tracking_transformations(asts)
    default_transformations(asts)
    begin
      tables_to_fields = process_fields_and_transform_schema(asts[:migration])     
      models_to_fields = convert(tables_to_fields)
    rescue
      tables_to_fields={};
      models_to_fields={};
    end

    for filename in asts[:model].keys do
      #disallow_features(asts[:model][filename])
      transform_model(asts[:model][filename], models_to_fields[filename])
    end

    for filename in asts[:controller].keys do
      #disallow_features(asts[:controller][filename]) if filename == "users_controller.rb"
    end
    asts[:taint_migration]= create_taint_migration models_to_fields
  end

  def interp_to_concat(ast)
    return unless ast.is_a? Sexp

    for i in ast.each_index

      if ast[i].is_a? Sexp
        x = convert_to_concat(ast[i][1..-1]) if ast[i][0] == :dstr
        pp ast[i] if x != nil
        ast[i] = x if x != nil
        puts "" if x != nil
        interp_to_concat(ast[i])
      end
    end
  end

  def convert_to_concat(sexp)
    curr = sexp[0]

    # The last statement is either
    if sexp.length == 1
      if curr.is_a? String
        # curr is of form s("..")
        return Sexp.from_array [:str, curr]

      elsif curr[0] == :str
        # curr is of form s(:str, "..")
        return curr

      elsif curr[0] == :evstr
        # curr if of form s(:evstr, s(..))
        empty_args = Sexp.from_array [:arglist]
        return Sexp.from_array [:call, curr[1], :to_s, empty_args]
      else
        puts "error"
        pp sexp
      end
    end

    # The caller is either a raw string, string sexp, or expression to eval
    if curr.is_a? String
      # curr is of form s("..")
      caller = Sexp.from_array [:str, curr]

    elsif curr[0] == :str
      # curr is of form s(:str, "..")
      caller = curr

    else
      # curr if of form s(:evstr, s(..))
      empty_args = Sexp.from_array [:arglist]
      caller = Sexp.from_array [:call, curr[1], :to_s, empty_args]
    end

    # The rest of the string becomes the second argument to +
    args = Sexp.from_array [:arglist, convert_to_concat(sexp[1..-1])]

    return Sexp.from_array [:call, caller, :+, args]
  end

end
