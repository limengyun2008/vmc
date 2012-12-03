FactoryGirl.define do
  factory :app, :class => CFoundry::V2::App do
    name { FactoryGirl.generate(:random_string) }
    memory 128
    total_instances 0
    production false

    initialize_with do
      CFoundry::V2::App.new(nil, nil)
    end
  end
end
