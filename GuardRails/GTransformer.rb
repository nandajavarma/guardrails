require 'ruby_parser'
require 'GSexp'
require 'GStringTransformer'
require 'GForm'
require 'pp'

class GTransformer
  # Transformations that happen to all model files
  def universal_transformations(ast)
    ast = ast.insert_at_front(@parser.parse("require 'GObject'; require 'wrapper'"))

    ast.insert_into_class! @parser.parse("unloadable"), true
    ast.insert_into_class!(@parser.parse(
    "include Wrapper; include Wrapper::WrapperMethods"), true)
    ast.insert_into_class!(@parser.parse("public"))
    ast.insert_into_class!(@parser.parse("define_attribute_methods"))

    return ast
  end

  # Transformations to build the policy and violation hashes
  def build_policy_objects(ast, ann_list)
    return ast if ann_list.nil?

    function = "def populate_policies\n"
    privilege = ""
    for ann in ann_list do
      function += "Thread.current['loopbreak']=true\n"
      function += "x=#{ann.target}\n"
      function += "Thread.current['loopbreak']=false\n"
      function += "x.assign_violation (:#{ann.policy}, '#{ann.violation.to_s}', :self, self, '#{ann.target}')\n" unless ann.violation.nil?
      function += "x.assign_policy (:#{ann.policy}, '#{ann.lambda.to_s}', :self, self, '#{ann.target}')\n" unless ann.type==:func
    end
    function += "end"
    ast.insert_into_class!(@parser.parse(function))

    function = "def self.populate_policies\n"
    for ann in ann_list do
      if ann.type == :class
        #                          puts "---- #{ann.lambda.inspect} + #{ann.lambda.class}"
        # function += "#{ann.target}.assign_policy (:#{ann.policy}, '#{ann.lambda.to_s}')\n"
        function += "Thread.current['loopbreak']=true\n"
        function += "x=#{ann.target}\n"
        function += "Thread.current['loopbreak']=false\n"
        function += "x.assign_violation (:#{ann.policy}, '#{ann.violation.to_s}', :self, self, '#{ann.target}')\n" unless ann.violation.nil?
        function += "x.assign_policy (:#{ann.policy}, '#{ann.lambda.to_s}', :self, self, '#{ann.target}')\n" unless ann.type==:func
      elsif ann.type == :func
        #        puts "Here is a func annotation #{ann.target}"
        privilege+="alias :gr_#{ann.target} :#{ann.target}\ndef #{ann.target} *args, &body\n"
        privilege+="  policy_temp=Thread.current['override_policy']\n"
        privilege+="  Thread.current['override_policy']=#{ann.lambda.to_s}\n"
        privilege+="  return_temp=send \'gr_#{ann.target}\', *args, &body\n"
        privilege+="  Thread.current['override_policy']=policy_temp\n  return return_temp\nend\n"
      end
    end
    function += "end\n"+privilege
    begin
      ast.insert_into_class!(@parser.parse(function))
    rescue
      puts privilege
      exit
    end

    return ast
  end

  # Transformations to enforce policies
  def access_policy_transformations(ast)
    ast.insert_into_class! @parser.parse("gr_policy_setup")
    return ast
  end

  # Replaces all references to Models in target ast with a ModelProxyObject.
  # We do this so we can intercept calls like [Model].find and [Model].delete
  def insert_model_proxies(ast, model_list, filename="")
    for model_name in model_list
      if ast.replace2!(model_name.to_sym, "gr_#{model_name}".to_sym)
        #puts "#{model_name} is being replaced in #{filename}"
        ast.insert_into_class! @parser.parse(
        "def gr_#{model_name}; ModelProxy.new(#{model_name}); end")
        ast.insert_into_class! @parser.parse(
        "def self.gr_#{model_name}; ModelProxy.new(#{model_name}); end")
        ast.insert_into_class! @parser.parse(
        "#{model_name}.populate_policies")
      end
    end
    return ast
  end

  def insert_view_model_proxies(ast, model_list, filename="")
    for model_name in model_list
      if ast.replace2!(model_name.to_sym, "@gr_#{model_name}".to_sym)
        #     puts "#{model_name} is being replaced in #{filename}"
        ast=ast.insert_at_front @parser.parse(
        "#{model_name}.populate_policies")
        ast=ast.insert_at_front @parser.parse(
        "@gr_#{model_name} = Wrapper::ModelProxy.new(#{model_name})")
      end
    end
    return ast
  end

  def insert_requires(ast, require_list)
    for req in require_list
      ast=ast.insert_at_front @parser.parse("require "+req.inspect)
    end
    ast
  end

  def regex_replace(ast)
    ast.replace! :$~, :$gr_md
    ast.replace! '$&'.to_sym, :$gr_and
    ast.replace! '$`'.to_sym, :$gr_left
    ast.replace! "$'".to_sym, :$gr_right
    ast.replace! "$+".to_sym, :$gr_plus
    ast
  end

  def get_initial_populate_policy models
    ans="def initial_populate_policy\n"
    for i in models
      ans+=i.to_s+".populate_policies\n"
    end
    return ans+"end\n"
  end

  def transform(asts, ann_lists, model_names, model_filenames, pass_user, require_list=[])
    @parser = RubyParser.new

    #puts "adding requires: #{require_list}"

    # Transform the models to have policy mappings and such
    for filename in asts[:model].keys do

      # Only transform models that extend ActiveRecord::Base
      next unless model_filenames.include? filename

      ast = asts[:model][filename]
      ann_list = ann_lists[filename]

      ast = universal_transformations(ast)
      ast=insert_model_proxies(ast,model_names,filename)
      ast = build_policy_objects(ast, ann_list)
      ast = access_policy_transformations(ast)
      ast=insert_requires(ast,require_list)
      ast=regex_replace(ast)
      asts[:model][filename] = ast
    end

    # Transform the controllers to include the proper files and have model proxies
    for filename in asts[:controller].keys do
      ast = asts[:controller][filename]
      ast = ast.insert_at_front(@parser.parse("require 'wrapper'"))
      ast.insert_into_class!(@parser.parse(
      "include Wrapper; include Wrapper::WrapperMethods"), true)

      ast.insert_into_class! @parser.parse("unloadable"), true

      ast = insert_model_proxies(ast, model_names,filename)
      ast=insert_requires(ast,require_list)
      ast=regex_replace(ast)

      asts[:controller][filename] = ast
    end

    for filename in asts[:library].keys do
      ast=asts[:library][filename]
      next if ast.nil?
      ast = ast.insert_at_front(@parser.parse("require 'wrapper'"))
      ast.insert_into_class!(@parser.parse(
      "include Wrapper; include Wrapper::WrapperMethods"), true)
      ast.insert_into_class! @parser.parse("unloadable"), true
      ast=insert_model_proxies(ast,model_names,filename)
      ast=insert_requires(ast,require_list)
      ast=regex_replace(ast)
      asts[:library][filename]=ast
    end

    @form_for_alterer=GForm.new
    for filename in asts[:view].keys do
      ast=asts[:view][filename]
      #ast = ast.insert_at_front(@parser.parse("include 'wrapper'"))
      ast=insert_view_model_proxies(ast,model_names,filename) unless ast.nil?
      ast=regex_replace(ast) unless ast.nil?
      @form_for_alterer.alterFormFors ast, @parser
      asts[:view][filename]=ast
    end

    # Application helper needs a new function
    asts[:helper].insert_into_class! @parser.parse(
    'def protect
    		 	yield
    			@output_buffer = @output_buffer.transform(:HTML)
			 end')
    regex_replace(asts[:helper])

    # Handle taint tracking transformations
    taint_tracking_transformations(asts)

    # We need the models to have access to the authentication information so they can decide
    # about authorization.
    app_control = asts[:controller]['application_controller.rb']
    app_control = asts[:controller]['application.rb'] if app_control.nil?
    app_control.insert_class_stmt @parser.parse("before_filter :pass_user"), true
    app_control.insert_class_stmt @parser.parse("before_filter :initial_populate_policy"), true
    app_control.insert_class_stmt @parser.parse(pass_user)
    app_control.insert_class_stmt @parser.parse(get_initial_populate_policy(model_names))
  end
end
