angular.module('factories').factory('Pagination', function () {

  return function(apiResponse) {

    this.page       = apiResponse.config.params.page || 1;
    this.perPage    = apiResponse.config.params.per_page || 25;
    this.totalItems = apiResponse.headers()['total-items'];
    this.totalPages = apiResponse.headers()['total-pages'];

  };

});