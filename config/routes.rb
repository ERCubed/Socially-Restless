Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "health", to: "health#show"

  get "api-docs", to: "docs#show"
  get "api-docs/openapi.yaml", to: "docs#openapi"

  namespace :api do
    namespace :v1 do
      resources :users, only: [ :create ], param: :username do
        resources :posts, only: [ :index ], controller: "users/posts"
      end
      resource :session, only: [ :create, :destroy ]
      resources :posts, only: [ :show, :create, :destroy ] do
        resource :rating, only: [ :create ]
      end
      get "timeline", to: "timeline#index"
    end
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
