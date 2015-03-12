require 'contracts/core_ext'
require 'contracts/support'
require 'contracts/method_reference'
require 'contracts/errors'
require 'contracts/decorators'
require 'contracts/eigenclass'
require 'contracts/builtin_contracts'
require 'contracts/modules'
require 'contracts/invariants'

module Contracts
  def self.included(base)
    common(base)
  end

  def self.extended(base)
    common(base)
  end

  def self.common(base)
    Eigenclass.lift(base)

    return if base.respond_to?(:Contract)

    base.extend(MethodDecorators)

    base.instance_eval do
      def functype(funcname)
        contracts = self.decorated_methods[:class_methods][funcname]
        if contracts.nil?
          "No contract for #{self}.#{funcname}"
        else
          "#{funcname} :: #{contracts[0]}"
        end
      end
    end

    base.class_eval do
      unless base.instance_of?(Module)
        def Contract(*args)
          return if ENV["NO_CONTRACTS"]
          self.class.Contract(*args)
        end
      end

      def functype(funcname)
        contracts = self.class.decorated_methods[:instance_methods][funcname]
        if contracts.nil?
          "No contract for #{self.class}.#{funcname}"
        else
          "#{funcname} :: #{contracts[0]}"
        end
      end
    end
  end
end

# This is the main Contract class. When you write a new contract, you'll
# write it as:
#
#   Contract [contract names] => return_value
#
# This class also provides useful callbacks and a validation method.
class Contract < Contracts::Decorator
  # Default implementation of failure_callback. Provided as a block to be able
  # to monkey patch #failure_callback only temporary and then switch it back.
  # First important usage - for specs.
  DEFAULT_FAILURE_CALLBACK = Proc.new do |data|
    raise data[:contracts].failure_exception.new(failure_msg(data), data)
  end

  attr_reader :args_contracts, :ret_contract, :klass, :method
  # decorator_name :contract
  def initialize(klass, method, *contracts)
    if contracts[-1].is_a? Hash
      # internally we just convert that return value syntax back to an array
      @args_contracts = contracts[0, contracts.size - 1] + contracts[-1].keys
      @ret_contract = contracts[-1].values[0]
      @args_validators = @args_contracts.map do |contract|
        Contract.make_validator(contract)
      end
      @ret_validator = Contract.make_validator(@ret_contract)
    else
      fail "It looks like your contract for #{method} doesn't have a return value. A contract should be written as `Contract arg1, arg2 => return_value`."
    end
    @klass, @method = klass, method
    @splat_lower_index = @args_contracts.index do |contract|
      contract.is_a? Contracts::Args
    end
    last_contract = @args_contracts.last
    @has_proc_contract = Contracts::Func === last_contract || (
        Class === last_contract &&
        (last_contract <= Proc || last_contract <= Method)
      )
    penultimate_contract = @args_contracts[-2]
    @has_options_contract = @has_proc_contract ? Hash === penultimate_contract :
                                                 Hash === last_contract
  end

  def pretty_contract c
    c.is_a?(Class) ? c.name : c.class.name
  end

  def to_s
    args = @args_contracts.map { |c| pretty_contract(c) }.join(", ")
    ret = pretty_contract(@ret_contract)
    ("#{args} => #{ret}").gsub("Contracts::", "")
  end

  # Given a hash, prints out a failure message.
  # This function is used by the default #failure_callback method
  # and uses the hash passed into the failure_callback method.
  def self.failure_msg(data)
   expected = if data[:contract].to_s == "" || data[:contract].is_a?(Hash)
                data[:contract].inspect
              else
                data[:contract].to_s
              end

   position = Contracts::Support.method_position(data[:method])
   method_name = Contracts::Support.method_name(data[:method])

   header = if data[:return_value]
     "Contract violation for return value:"
   else
     "Contract violation for argument #{data[:arg_pos]} of #{data[:total_args]}:"
   end

%{#{header}
    Expected: #{expected},
    Actual: #{data[:arg].inspect}
    Value guarded in: #{data[:class]}::#{method_name}
    With Contract: #{data[:contracts]}
    At: #{position} }
  end

  # Callback for when a contract fails. By default it raises
  # an error and prints detailed info about the contract that
  # failed. You can also monkeypatch this callback to do whatever
  # you want...log the error, send you an email, print an error
  # message, etc.
  #
  # Example of monkeypatching:
  #
  #   def Contract.failure_callback(data)
  #     puts "You had an error!"
  #     puts failure_msg(data)
  #     exit
  #   end
  def self.failure_callback(data, use_pattern_matching=true)
    if data[:contracts].pattern_match? && use_pattern_matching
      return DEFAULT_FAILURE_CALLBACK.call(data)
    end

    fetch_failure_callback.call(data)
  end

  # Used to override failure_callback without monkeypatching.
  #
  # Takes: block parameter, that should accept one argument - data.
  #
  # Example usage:
  #
  #   Contract.override_failure_callback do |data|
  #     puts "You had an error"
  #     puts failure_msg(data)
  #     exit
  #   end
  def self.override_failure_callback(&blk)
    @failure_callback = blk
  end

  # Used to restore default failure callback
  def self.restore_failure_callback
    @failure_callback = DEFAULT_FAILURE_CALLBACK
  end

  def self.fetch_failure_callback
    @failure_callback ||= DEFAULT_FAILURE_CALLBACK
  end

  # Used to verify if an argument satisfies a contract.
  #
  # Takes: an argument and a contract.
  #
  # Returns: a tuple: [Boolean, metadata]. The boolean indicates
  # whether the contract was valid or not. If it wasn't, metadata
  # contains some useful information about the failure.
  def self.valid?(arg, contract)
    make_validator(contract)[arg]
  end

  # This is a little weird. For each contract
  # we pre-make a proc to validate it so we
  # don't have to go through this decision tree every time.
  # Seems silly but it saves us a bunch of time (4.3sec vs 5.2sec)
  def self.make_validator(contract)
    # if is faster than case!
    klass = contract.class
    if klass == Proc
      # e.g. lambda {true}
      contract
    elsif klass == Array
      # e.g. [Num, String]
      # TODO account for these errors too
      lambda { |arg|
        return false unless arg.is_a?(Array) && arg.length == contract.length
        arg.zip(contract).all? do |_arg, _contract|
          Contract.valid?(_arg, _contract)
        end
      }
    elsif klass == Hash
      # e.g. { :a => Num, :b => String }
      lambda { |arg|
        return false unless arg.is_a?(Hash)
        contract.keys.all? do |k|
          Contract.valid?(arg[k], contract[k])
        end
      }
    elsif klass == Contracts::Args
      lambda { |arg|
        Contract.valid?(arg, contract.contract)
      }
    elsif klass == Contracts::Func
      lambda { |arg|
        arg.is_a?(Method) || arg.is_a?(Proc)
      }
    else
      # classes and everything else
      # e.g. Fixnum, Num
      if contract.respond_to? :valid?
        lambda { |arg| contract.valid?(arg) }
      elsif klass == Class
        lambda { |arg| arg.is_a?(contract) }
      else
        lambda { |arg| contract == arg }
      end
    end
  end

  def [](*args, &blk)
    call(*args, &blk)
  end

  def call(*args, &blk)
    call_with(nil, *args, &blk)
  end

  def call_with(this, *args, &blk)
    _args = blk ? args + [blk] : args

    args_size = args.size
    _args_size = _args.size
    contracts_size = args_contracts.size

    # Explicitly append blk=nil if nil != Proc contract violation anticipated
    if @has_proc_contract && !blk &&
      (@splat_lower_index || _args_size < contracts_size)
      _args << nil
      _args_size += 1
    end

    # Explicitly append options={} if Hash contract is present
    if @has_options_contract
      if @has_proc_contract && Hash === @args_contracts[-2] && !_args[-2].is_a?(Hash)
        _args.insert(-2, {})
        _args_size += 1
      elsif Hash === @args_contracts[-1] && !_args[-1].is_a?(Hash)
        _args << {}
        _args_size += 1
      end
    end

    # Loop forward validating the arguments up to the splat (if there is one)
    (@splat_lower_index || _args_size).times do |i|
      _arg = _args[i]
      contract = @args_contracts[i]
      validator = @args_validators[i]


      unless validator && validator[_arg]
        return unless Contract.failure_callback({
          :arg => _arg,
          :contract => contract,
          :class => @klass,
          :method => @method,
          :contracts => self,
          :arg_pos => i + 1,
          :total_args => args_size
        })
      end

      if contract.is_a?(Contracts::Func)
        _args[i] = Contract.new(@klass, _arg, *contract.contracts)
      end
    end

    # If there is a splat loop backwards to the lower index of the splat
    # Once we hit the splat in this direction set its upper index
    # Keep validating but use this upper index to get the splat validator.
    if @splat_lower_index
      splat_upper_index = @splat_lower_index
      (_args_size - @splat_lower_index).times do |i|
        _arg = _args[_args_size - 1 - i]

        if Contracts::Args === @args_contracts[contracts_size - 1 - i]
          splat_upper_index = i
        end

        # Each arg after the spat is found must use the splat validator
        j = i < splat_upper_index ? i : splat_upper_index
        contract = @args_contracts[contracts_size - 1 - j]
        validator = @args_validators[contracts_size - 1 - j]

        unless validator && validator[_arg]
          return unless Contract.failure_callback({
            :arg => _arg,
            :contract => contract,
            :class => @klass,
            :method => @method,
            :contracts => self,
            :arg_pos => args_size - i,
            :total_args => args_size
          })
        end

        if contract.is_a?(Contracts::Func)
          _args[_args_size - 1 - i] =
            Contract.new(@klass, _arg, *contract.contracts)
        end
      end
    end

    # If we put the block into _args for validating, restore the args
    args = _args[0..-2] if blk


    result = if @method.respond_to?(:call)
      # proc, block, lambda, etc
      @method.call(*args, &blk)
    else
      # original method name referrence
      @method.send_to(this, *args, &blk)
    end

    unless @ret_validator[result]
      Contract.failure_callback({:arg => result, :contract => @ret_contract, :class => @klass, :method => @method, :contracts => self, :return_value => true})
    end

    this.verify_invariants!(@method) if this.respond_to?(:verify_invariants!)

    result
  end

  # Used to determine type of failure exception this contract should raise in case of failure
  def failure_exception
    if @pattern_match
      PatternMatchingError
    else
      ContractError
    end
  end

  # @private
  # Used internally to mark contract as pattern matching contract
  def pattern_match!
    @pattern_match = true
  end

  # Used to determine if contract is a pattern matching contract
  def pattern_match?
    @pattern_match
  end
end
